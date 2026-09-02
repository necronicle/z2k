package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// sessionDialFn — как сессия дозванивается до DC. Тесты подменяют.
var sessionDialFn dialAttemptFunc = (&net.Dialer{}).DialContext

type session struct {
	id       string
	relayID  string
	clientIP string
	prV      atomic.Pointer[protoHolder] // читают горутины стримов и drain
	build    string
	ws       *websocket.Conn
	started  time.Time

	dialCtx    context.Context
	dialCancel context.CancelFunc
	dialFn     dialAttemptFunc
	done       chan struct{}
	once       sync.Once

	reasonOnce  sync.Once
	reason      string
	peakStreams atomic.Int32
	rxBytes     atomic.Int64
	txBytes     atomic.Int64

	noisyMu sync.Mutex
	noisyN  map[string]int

	writer *wsWriter

	mu      sync.Mutex
	streams map[uint16]*stream

	connectSlots chan struct{}
	nonce        [16]byte
}

func newSession(ws *websocket.Conn, id, ip string, parent context.Context) *session {
	dialCtx, dialCancel := context.WithCancel(parent)
	s := &session{
		id: id, clientIP: ip, ws: ws, started: time.Now(),
		dialCtx: dialCtx, dialCancel: dialCancel, dialFn: sessionDialFn,
		done: make(chan struct{}), streams: map[uint16]*stream{}, connectSlots: newConnectSlots(),
	}
	s.setProto(protoV1)
	s.writer = newWSWriter(s)
	return s
}

// protoHolder — обёртка для atomic.Pointer: v1 и v2 разные типы.
type protoHolder struct{ p proto }

func (s *session) proto() proto     { return s.prV.Load().p }
func (s *session) setProto(p proto) { s.prV.Store(&protoHolder{p: p}) }

// run — вся жизнь сессии: рукопожатие, reader, смерть. Возвращается, когда
// сессия закрыта и все стримы сняты.
func (s *session) run() {
	registerLiveSession(s)
	defer unregisterLiveSession(s)
	go s.writer.run()
	defer s.kill()
	if !s.handshake() {
		return
	}
	emitEvent(Event{Ev: "session_open", SID: s.id, IP: s.clientIP, ASN: asnLookup(s.clientIP), Proto: s.proto().name(), Install: s.relayID})
	if s.relayID != "" {
		if ok, why := acquireInstallSession(s.relayID, s.clientIP, s); !ok {
			log.Printf("[%s] отказ установке %s: %s", s.id, s.relayID, why)
			s.goodbye(rOverloaded, why)
			s.killWith("install_refused")
			return
		}
		defer func() {
			rx, tx := s.bytes()
			releaseInstallSession(s.relayID, s, rx, tx)
		}()
	}
	log.Printf("[%s] authenticated (proto=%s id=%s build=%q)", s.id, s.proto().name(), s.relayID, s.build)
	if f := s.proto().info(infoAuthOK, uint32(*maxStreamsPerSess), ""); f != nil {
		s.writer.control(f)
	}
	s.readLoop()
}

func (s *session) readLoop() {
	for {
		_, msg, err := s.ws.ReadMessage()
		if err != nil {
			if *verbose {
				log.Printf("[%s] read err: %v", s.id, err)
			}
			s.killWith(classifyReadErr(err, "read_err"))
			return
		}
		_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
		sid, mt, payload, err := decodeFrame(msg)
		if err != nil {
			if s.proto().windows() {
				s.goodbye(rProtocol, "кадр короче 3 байт")
				s.killWith("protocol")
				return
			}
			continue
		}
		if sid == 0 {
			if s.proto().windows() {
				s.goodbye(rProtocol, fmt.Sprintf("кадр 0x%02x на стриме 0", mt))
				s.killWith("protocol")
				return
			}
			continue
		}
		switch mt {
		case muxCONNECT:
			s.onConnect(sid, payload)
		case muxDATA:
			if st := s.lookup(sid); st != nil {
				st.fromClient(payload)
			}
		case muxCLOSE:
			if st := s.lookup(sid); st != nil {
				st.finish("peer_close")
			}
		case muxWINDOW:
			if st := s.lookup(sid); st != nil && s.proto().windows() {
				if c, err := decodeWindow(payload); err == nil {
					st.grant(c)
				} else {
					st.abort(rProtocol, "WINDOW не 4 байта")
				}
			}
		default:
			if st := s.lookup(sid); st != nil && s.proto().windows() {
				st.abort(rProtocol, fmt.Sprintf("неизвестный тип 0x%02x", mt))
			} else if *verbose {
				log.Printf("[%s] unknown msg type 0x%02x stream=%d", s.id, mt, sid)
			}
		}
	}
}

func (s *session) lookup(id uint16) *stream {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.streams[id]
}

func (s *session) removeStream(st *stream) {
	s.mu.Lock()
	if cur, ok := s.streams[st.id]; ok && cur == st {
		delete(s.streams, st.id)
	}
	s.mu.Unlock()
}

func (s *session) onConnect(id uint16, payload []byte) {
	addr, port, err := parseConnectPayload(payload)
	if err != nil {
		s.writer.control(s.proto().connectFail(id, rProtocol, "плохой CONNECT"))
		return
	}
	target := targetOf(addr, port)
	if !isTelegramAddr(addr) {
		if s.noisy("rejected_non_tg") {
			log.Printf("[%s] stream %d rejected non-Telegram %s", s.id, id, target)
		}
		emitEvent(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "not_allowed", Detail: target})
		s.writer.control(s.proto().connectFail(id, rNotAllowed, "адресат не Telegram"))
		return
	}
	if !s.acquireConnectSlot() {
		if s.noisy("connect_limit") {
			log.Printf("[%s] stream %d: превышен потолок одновременных CONNECT (%d)", s.id, id, *maxPendingConnects)
		}
		s.writer.control(s.proto().connectFail(id, rStreamLimit, "слишком много дозвонов"))
		return
	}
	st := s.newStream(id, target)
	s.mu.Lock()
	old, replacing := s.streams[id]
	if !replacing && *maxStreamsPerSess > 0 && len(s.streams) >= *maxStreamsPerSess {
		s.mu.Unlock()
		s.releaseConnectSlot()
		if s.noisy("stream_limit") {
			log.Printf("[%s] stream %d: превышен потолок стримов на сессию (%d)", s.id, id, *maxStreamsPerSess)
		}
		emitEvent(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "stream_limit", Detail: target})
		s.writer.control(s.proto().connectFail(id, rStreamLimit, "потолок стримов"))
		return
	}
	s.streams[id] = st
	liveStreams.Add(1)
	active := int32(len(s.streams))
	s.mu.Unlock()
	for {
		cur := s.peakStreams.Load()
		if active <= cur || s.peakStreams.CompareAndSwap(cur, active) {
			break
		}
	}
	if replacing {
		old.abort(rReplaced, "стрим пересоздан")
	}
	go func() {
		defer s.releaseConnectSlot()
		st.dial()
	}()
}

// goodbye — INFO GOODBYE(reason) и WS Close 1008 с тем же кодом; ждёт, пока
// писатель отправит оба (v1: только Close).
func (s *session) goodbye(reason byte, text string) {
	msg := websocket.FormatCloseMessage(websocket.ClosePolicyViolation, reasonName(reason))
	s.writer.controlThenClose(s.proto().info(infoGoodbye, uint32(reason), text), msg, 2*time.Second)
}

func (s *session) killWith(reason string) {
	s.reasonOnce.Do(func() { s.reason = reason })
	s.kill()
}

func (s *session) closeReason() string {
	s.reasonOnce.Do(func() { s.reason = "peer_close" })
	return s.reason
}

func (s *session) kill() {
	s.once.Do(func() {
		close(s.done)
		s.dialCancel()
		_ = s.ws.Close()
		s.mu.Lock()
		list := make([]*stream, 0, len(s.streams))
		for _, st := range s.streams {
			list = append(list, st)
		}
		s.mu.Unlock()
		for _, st := range list {
			st.finish("session_close")
		}
	})
}

func (s *session) bytes() (int64, int64) { return s.rxBytes.Load(), s.txBytes.Load() }

func (s *session) emitStreamClose(st *stream, reason string) {
	if !st.closeReason.CompareAndSwap(nil, reason) {
		return
	}
	liveStreams.Add(-1)
	metrics.inc("relay_stream_close_total", fmt.Sprintf("reason=%q", reason))
	emitEvent(Event{Ev: "stream_close", SID: s.id, Install: s.relayID, Reason: reason,
		DurMS: time.Since(st.opened).Milliseconds(), Detail: st.target})
}

// heaviestStream — для триммера бюджета (спека §3.3).
func (s *session) heaviestStream() (*stream, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best *stream
	var max int64
	for _, st := range s.streams {
		if q := st.outq.queued() + st.upq.queued(); q > max {
			best, max = st, q
		}
	}
	return best, max
}

// --- троттлинг строк (план 1, без изменений) ---

const noisyPrintLimit = 3

// noisy считает повторяющиеся отказы одной сессии и разрешает печать
// только первых трёх: одна установка с самонабором давала 13 тысяч строк
// за два часа и вымывала журнал релея до пяти часов истории (02.09.2026).
func (s *session) noisy(kind string) bool {
	s.noisyMu.Lock()
	defer s.noisyMu.Unlock()
	if s.noisyN == nil {
		s.noisyN = map[string]int{}
	}
	s.noisyN[kind]++
	return s.noisyN[kind] <= noisyPrintLimit
}

func (s *session) noisyDetail() string {
	s.noisyMu.Lock()
	defer s.noisyMu.Unlock()
	if len(s.noisyN) == 0 {
		return ""
	}
	keys := make([]string, 0, len(s.noisyN))
	for k := range s.noisyN {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, s.noisyN[k]))
	}
	return strings.Join(parts, " ")
}

func authRejectClass(why string) string {
	switch {
	case strings.HasPrefix(why, "часы разошлись"):
		return "clock_skew"
	case strings.HasPrefix(why, "повтор подписи"):
		return "replay"
	default:
		return "other"
	}
}

// classifyReadErr сводит ошибку чтения WS к причине события: таймаут —
// read_timeout, штатное закрытие пиром — peer_close, остальное — prefix.
func classifyReadErr(err error, prefix string) string {
	if isTimeoutErr(err) {
		if prefix == "auth_read_err" {
			return "auth_read_err:timeout"
		}
		return "read_timeout"
	}
	if websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway, websocket.CloseNoStatusReceived) || errors.Is(err, io.EOF) {
		if prefix == "auth_read_err" {
			return "auth_read_err:eof"
		}
		return "peer_close"
	}
	return prefix
}

// liveStreams — стримы с открытым сокетом к DC; инкремент при вставке в
// карту сессии, декремент ровно один раз в emitStreamClose.
var liveStreams atomic.Int64

// buildVersion подставляется сборкой (-X main.buildVersion=...).
var buildVersion = "dev"

// Глобалы дозвона: лимитер и сводка (жили рядом со старым ядром).
var (
	dialThrottle *dialLimiter
	stats        = &dialStats{}
)
