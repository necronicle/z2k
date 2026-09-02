package main

import (
	"context"
	"errors"
	"log"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const (
	stPending int32 = iota
	stOpen
	stClosed
)

// Очередь к клиенту в v2 ограничена кредитом клиента, а не нашим потолком;
// потолок здесь — только страховка от ошибки учёта.
const v2OutQueueCap = 16 * 1024 * 1024

// stream — один туннелируемый TCP к DC (спека §3.2). Две очереди: upq
// (кадры от клиента, ждут записи в DC) и outq (кадры к клиенту, ждут WS).
// Две горутины-насоса с дедлайнами. Ни одна из них не держит reader сессии.
type stream struct {
	id     uint16
	s      *session
	target string
	opened time.Time

	state        atomic.Int32
	closeOnce    sync.Once
	closeReason  atomic.Value // string для событий
	flushOnClose atomic.Bool  // EOF: хвост outq дописать; abort: выбросить
	inRing       atomic.Bool

	connMu sync.Mutex
	conn   net.Conn

	upq  *byteQueue
	outq *byteQueue

	// v2: кредит, который клиент выдал нам (сколько ещё можно послать), и
	// сколько мы получили от клиента и ещё не подтвердили кадром WINDOW.
	creditToClient atomic.Int64
	creditWake     chan struct{}
	recvUnacked    atomic.Int64
	window         int64

	dialCancel context.CancelFunc
}

func (s *session) newStream(id uint16, target string) *stream {
	win := int64(*defaultWindow)
	upCap, outCap := win, int64(v2OutQueueCap)
	if !s.proto().windows() {
		upCap, outCap = int64(*perStreamQueueBytes), int64(*perStreamQueueBytes)
	}
	st := &stream{
		id: id, s: s, target: target, opened: time.Now(), window: win,
		upq: newByteQueue(upCap), outq: newByteQueue(outCap), creditWake: make(chan struct{}, 1),
	}
	st.creditToClient.Store(win)
	return st
}

func (st *stream) isClosed() bool { return st.state.Load() == stClosed }

// dial — из горутины: лимитер (установка|адресат, затем адресат), дозвон
// с отменой по CLOSE клиента, затем CONNECT_OK/FAIL.
func (st *stream) dial() {
	s := st.s
	ctx, cancel := context.WithCancel(s.dialCtx)
	st.connMu.Lock()
	st.dialCancel = cancel
	closed := st.isClosed()
	st.connMu.Unlock()
	defer cancel()
	if closed {
		return
	}

	release, err := dialThrottle.acquire2(ctx, s.relayID, st.target)
	if err != nil {
		if errors.Is(err, errDialThrottle) {
			stats.record(false, true, false, 0)
			emitEvent(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "throttled", Detail: st.target})
			st.fail(rDialThrottled, "лимит дозвонов")
			return
		}
		st.finish("peer_close") // отменён клиентом
		return
	}
	t0 := time.Now()
	conn, attempt, err := dialWithRetry(ctx, s.dialFn, st.target, *dialPerAttemptTimeout, 1+*dialRetryCount, *dialRetryBackoff)
	release()
	if err != nil {
		if errors.Is(err, context.Canceled) || st.isClosed() {
			st.finish("peer_close")
			return
		}
		stats.record(false, false, false, 0)
		if s.noisy("dial_failed") {
			log.Printf("[%s] stream %d dial %s failed (attempts=%d): %v", s.id, st.id, st.target, attempt+1, err)
		}
		emitEvent(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "dial_error", Detail: st.target})
		st.fail(rDialFailed, "дозвон не удался")
		return
	}
	lat := time.Since(t0)
	stats.record(true, false, attempt > 0, lat)
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(60 * time.Second)
	}
	st.connMu.Lock()
	if st.isClosed() {
		st.connMu.Unlock()
		_ = conn.Close()
		return
	}
	st.conn = conn
	st.state.Store(stOpen)
	st.connMu.Unlock()

	emitEvent(Event{Ev: "stream_open", SID: s.id, Install: s.relayID, DurMS: lat.Milliseconds(), Detail: st.target})
	s.writer.control(s.proto().connectOK(st.id, uint32(st.window)))
	go st.pumpToUpstream()
	go st.pumpFromUpstream()
}

// fail — дозвон не состоялся: CONNECT_FAIL с причиной, стрим снимается.
func (st *stream) fail(reason byte, text string) {
	st.closeOnce.Do(func() {
		st.state.Store(stClosed)
		st.teardown()
		st.s.removeStream(st)
		st.s.emitStreamClose(st, reasonName(reason))
		st.s.writer.control(st.s.proto().connectFail(st.id, reason, text))
	})
}

// abort — закрыть с причиной, хвост данных выбросить, клиенту CLOSE(reason)
// через приоритетную очередь.
func (st *stream) abort(reason byte, text string) {
	st.closeOnce.Do(func() {
		st.state.Store(stClosed)
		st.teardown()
		st.s.removeStream(st)
		st.s.emitStreamClose(st, reasonName(reason))
		st.s.writer.control(st.s.proto().closeFrame(st.id, reason, text))
	})
}

// finish — закрытие без кадра назад (CLOSE пришёл от клиента или сессия
// умирает): событие несёт причину словами.
func (st *stream) finish(reason string) {
	st.closeOnce.Do(func() {
		st.state.Store(stClosed)
		st.teardown()
		st.s.removeStream(st)
		st.s.emitStreamClose(st, reason)
	})
}

// eof — DC закрыл: хвост outq дописывается, за ним упорядоченный CLOSE(NORMAL).
func (st *stream) eof() {
	st.closeOnce.Do(func() {
		st.flushOnClose.Store(true)
		st.state.Store(stClosed)
		st.upq.close()
		st.connMu.Lock()
		if st.dialCancel != nil {
			st.dialCancel()
		}
		if st.conn != nil {
			_ = st.conn.Close()
		}
		st.connMu.Unlock()
		st.s.removeStream(st)
		st.s.emitStreamClose(st, "eof")
		frame := st.s.proto().closeFrame(st.id, rNormal, "")
		if !st.outq.push(frame) {
			st.s.writer.control(frame) // очередь полна — пусть уйдёт вне очереди
			return
		}
		budget.add(int64(len(frame)))
		st.s.writer.wake(st)
	})
}

func (st *stream) teardown() {
	st.connMu.Lock()
	if st.dialCancel != nil {
		st.dialCancel()
	}
	if st.conn != nil {
		_ = st.conn.Close()
	}
	st.connMu.Unlock()
	st.upq.close()
	budget.add(-st.outq.queued())
	st.outq.close()
	select {
	case st.creditWake <- struct{}{}:
	default:
	}
}

// fromClient — DATA от клиента: учёт окна, очередь к DC.
func (st *stream) fromClient(payload []byte) {
	s := st.s
	if st.state.Load() == stPending {
		if s.proto().windows() {
			st.abort(rProtocol, "DATA до CONNECT_OK")
		}
		return // v1: молча, как раньше
	}
	if s.proto().windows() && st.recvUnacked.Add(int64(len(payload))) > st.window {
		st.abort(rProtocol, "превышено окно")
		return
	}
	s.txBytes.Add(int64(len(payload)))
	if !st.upq.push(payload) {
		if st.isClosed() {
			return
		}
		if s.noisy("queue_abort") {
			log.Printf("[%s] stream %d очередь к DC переполнена", s.id, st.id)
		}
		st.abort(rQueueLimit, "очередь к адресату")
	}
}

// pumpToUpstream — единственный писатель в сокет DC.
func (st *stream) pumpToUpstream() {
	s := st.s
	var consumed int64
	for st.upq.wait(s.done) {
		p, ok := st.upq.pop()
		if !ok {
			continue
		}
		st.connMu.Lock()
		c := st.conn
		st.connMu.Unlock()
		if c == nil {
			return
		}
		_ = c.SetWriteDeadline(time.Now().Add(*upstreamWriteTimeout))
		if _, err := c.Write(p); err != nil {
			if st.isClosed() {
				return
			}
			if isTimeoutErr(err) {
				st.abort(rTimeout, "адресат не принимает данные")
			} else {
				st.abort(rPeerReset, "адресат сбросил соединение")
			}
			return
		}
		if s.proto().windows() {
			consumed += int64(len(p))
			if consumed >= st.window/2 {
				st.recvUnacked.Add(-consumed)
				s.writer.control(encodeFrame(st.id, muxWINDOW, encodeWindow(uint32(consumed))))
				consumed = 0
			}
		}
	}
}

// pumpFromUpstream — чтение DC в пределах кредита клиента (v2) или
// потолка стрима (v1). Без кредита сокет DC не читается: давление доходит
// до Telegram по TCP.
func (st *stream) pumpFromUpstream() {
	s := st.s
	bufp := readBufPool.Get().(*[]byte)
	buf := (*bufp)[:16*1024]
	defer readBufPool.Put(bufp)
	st.connMu.Lock()
	c := st.conn
	st.connMu.Unlock()
	if c == nil {
		return
	}
	for {
		if s.proto().windows() {
			for st.creditToClient.Load() <= 0 {
				select {
				case <-st.creditWake:
				case <-s.done:
					return
				}
				if st.isClosed() {
					return
				}
			}
		}
		want := len(buf)
		if s.proto().windows() {
			if cr := st.creditToClient.Load(); cr < int64(want) {
				want = int(cr)
			}
		}
		n, err := c.Read(buf[:want])
		if n > 0 {
			s.rxBytes.Add(int64(n))
			if s.proto().windows() {
				st.creditToClient.Add(-int64(n))
			}
			if !s.writer.data(st, encodeFrame(st.id, muxDATA, buf[:n])) {
				if st.isClosed() {
					return
				}
				if s.noisy("queue_abort") {
					log.Printf("[%s] stream %d очередь к клиенту переполнена", s.id, st.id)
				}
				st.abort(rQueueLimit, "очередь к клиенту")
				return
			}
		}
		if err != nil {
			if !st.isClosed() {
				st.eof()
			}
			return
		}
	}
}

// grant — WINDOW от клиента (v2).
func (st *stream) grant(credit uint32) {
	st.creditToClient.Add(int64(credit))
	select {
	case st.creditWake <- struct{}{}:
	default:
	}
}

func targetOf(addr string, port int) string { return net.JoinHostPort(addr, strconv.Itoa(port)) }
