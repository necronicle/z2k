package main

import (
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// ctrlItem — кадр приоритетной очереди. closeMsg — WS Close, который надо
// отправить сразу после кадра (GOODBYE); sent закрывается, когда всё ушло
// в сокет, чтобы вызывающий мог дождаться доставки до закрытия сессии.
type ctrlItem struct {
	frame    []byte
	closeMsg []byte
	sent     chan struct{}
}

// wsWriter — единственная горутина, пишущая в WS сессии (спека §3.2).
// ctrl — приоритетная очередь (HELLO_ACK, INFO, CONNECT_OK/FAIL, CLOSE по
// abort, WINDOW). Данные — по кругу стримов, по одному кадру за проход:
// один стрим не монополизирует канал.
type wsWriter struct {
	s         *session
	ctrl      chan ctrlItem
	ready     chan *stream
	pingEvery time.Duration
}

func newWSWriter(s *session) *wsWriter {
	return &wsWriter{
		s:         s,
		ctrl:      make(chan ctrlItem, *controlQueueDepth),
		ready:     make(chan *stream, 256),
		pingEvery: 30 * time.Second,
	}
}

// control ставит кадр в приоритетную очередь. Переполнение — сессия
// закрывается: очередь управления рассчитана на сотни кадров, её
// исчерпание значит, что клиент не читает вовсе.
func (w *wsWriter) control(frame []byte) bool {
	return w.push(ctrlItem{frame: frame})
}

// controlThenClose — кадр и следом WS Close; возвращается, когда оба ушли
// в сокет (или через timeout).
func (w *wsWriter) controlThenClose(frame, closeMsg []byte, timeout time.Duration) {
	it := ctrlItem{frame: frame, closeMsg: closeMsg, sent: make(chan struct{})}
	if !w.push(it) {
		return
	}
	select {
	case <-it.sent:
	case <-w.s.done:
	case <-time.After(timeout):
	}
}

func (w *wsWriter) push(it ctrlItem) bool {
	select {
	case w.ctrl <- it:
		return true
	case <-w.s.done:
		return false
	default:
		go w.s.killWith("control_queue")
		return false
	}
}

// data кладёт кадр в очередь стрима и, если стрим ещё не в круге, ставит
// его в круг. false — очередь стрима переполнена (вызывающий решает).
func (w *wsWriter) data(st *stream, frame []byte) bool {
	if !st.outq.push(frame) {
		return false
	}
	budget.add(int64(len(frame)))
	w.wake(st)
	return true
}

func (w *wsWriter) wake(st *stream) {
	if st.inRing.CompareAndSwap(false, true) {
		select {
		case w.ready <- st:
		case <-w.s.done:
			st.inRing.Store(false)
		}
	}
}

func (w *wsWriter) writeFrame(frame []byte) bool {
	_ = w.s.ws.SetWriteDeadline(time.Now().Add(*wsWriteTimeout))
	if err := w.s.ws.WriteMessage(websocket.BinaryMessage, frame); err != nil {
		if isTimeoutErr(err) {
			metrics.inc("relay_ws_write_timeouts_total", "")
			w.s.killWith("write_timeout")
		} else {
			if *verbose {
				log.Printf("[%s] write err: %v", w.s.id, err)
			}
			w.s.killWith("write_err")
		}
		return false
	}
	return true
}

func (w *wsWriter) writeCtrl(it ctrlItem) bool {
	if it.frame != nil && !w.writeFrame(it.frame) {
		return false
	}
	if it.closeMsg != nil {
		_ = w.s.ws.WriteControl(websocket.CloseMessage, it.closeMsg, time.Now().Add(2*time.Second))
	}
	if it.sent != nil {
		close(it.sent)
	}
	return true
}

func (w *wsWriter) run() {
	ping := time.NewTicker(w.pingEvery)
	defer ping.Stop()
	for {
		// Управление — вне очереди.
		select {
		case it := <-w.ctrl:
			if !w.writeCtrl(it) {
				return
			}
			continue
		default:
		}
		select {
		case it := <-w.ctrl:
			if !w.writeCtrl(it) {
				return
			}
		case st := <-w.ready:
			st.inRing.Store(false)
			f, ok := st.outq.pop()
			if !ok {
				continue
			}
			budget.add(-int64(len(f)))
			if st.isClosed() && !st.flushOnClose.Load() {
				continue // abort: хвост данных выбрасывается
			}
			if !w.writeFrame(f) {
				return
			}
			if st.outq.queued() > 0 {
				w.wake(st)
			}
		case <-ping.C:
			if err := w.s.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				log.Printf("[%s] ping failed: %v", w.s.id, err)
				w.s.killWith("ping_failed")
				return
			}
		case <-w.s.done:
			return
		}
	}
}

// wsWriteBufPool — общий пул буферов записи gorilla: без него каждая сессия
// держала бы свой буфер на всю жизнь (RAM-инцидент 12.07.2026).
var wsWriteBufPool = &sync.Pool{}
