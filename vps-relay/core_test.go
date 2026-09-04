package main

import (
	"bytes"
	"context"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// --- v2: рукопожатие и базовый поток ---------------------------------------

func TestV2_HandshakeAndEcho(t *testing.T) {
	m := withMemEvents(t)
	startFakeDC(t, echoDC)
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, ack := dialV2(t, url, id, priv, "r-82")
	if ack.DefaultWindow == 0 || ack.Ver != protoVersion2 {
		t.Fatalf("HELLO_ACK: %+v", ack)
	}
	sendFrame(t, ws, 1, muxCONNECT, connectPayload(tgTarget, 443))
	okp := expectFrame(t, ws, 1, muxCONNECT_OK, 2*time.Second)
	if decodeConnectOK(okp) != ack.DefaultWindow {
		t.Fatal("CONNECT_OK v2 несёт окно")
	}
	sendFrame(t, ws, 1, muxDATA, []byte("hello dc"))
	if got := expectFrame(t, ws, 1, muxDATA, 2*time.Second); string(got) != "hello dc" {
		t.Fatalf("эхо: %q", got)
	}
	if !m.wait("stream_open", 1, time.Second) {
		t.Fatal("нет stream_open")
	}
	if ev := m.byEv("session_open")[0]; ev.Proto != "v2" {
		t.Fatalf("proto в событии %q", ev.Proto)
	}
}

// --- v1: старый клиент обслуживается тем же ядром --------------------------

func TestV1Client_EchoAndEOFClose(t *testing.T) {
	m := withMemEvents(t)
	startFakeDC(t, func(c net.Conn) { c.Write([]byte("from dc")); c.Close() })
	url := startRelay(t)
	id, priv := testInstall(t)
	ws := dialV1(t, url, id, priv)
	sendFrame(t, ws, 5, muxCONNECT, connectPayload(tgTarget, 443))
	if p := expectFrame(t, ws, 5, muxCONNECT_OK, 2*time.Second); len(p) != 0 {
		t.Fatal("v1 CONNECT_OK обязан быть пустым")
	}
	if got := expectFrame(t, ws, 5, muxDATA, 2*time.Second); string(got) != "from dc" {
		t.Fatalf("данные: %q", got)
	}
	if p := expectFrame(t, ws, 5, muxCLOSE, 2*time.Second); len(p) != 0 {
		t.Fatal("v1 CLOSE обязан быть пустым")
	}
	if !m.wait("stream_close", 1, time.Second) || m.byEv("stream_close")[0].Reason != "eof" {
		t.Fatalf("stream_close: %+v", m.byEv("stream_close"))
	}
	if ev := m.byEv("session_open")[0]; ev.Proto != "v1" {
		t.Fatalf("proto %q", ev.Proto)
	}
}

// --- HOL: медленный DC одного стрима не тормозит соседний -------------------

func TestV2_SlowUpstreamDoesNotBlockSibling(t *testing.T) {
	startFakeDC(t, echoDC)
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, ack := dialV2(t, url, id, priv, "r-82")
	sendFrame(t, ws, 1, muxCONNECT, connectPayload(tgTarget, 80)) // чёрная дыра
	expectFrame(t, ws, 1, muxCONNECT_OK, 2*time.Second)
	sendFrame(t, ws, 2, muxCONNECT, connectPayload(tgTarget, 443)) // эхо
	expectFrame(t, ws, 2, muxCONNECT_OK, 2*time.Second)

	// Заливаем стрим 1 в пределах окна: DC не читает, записи встают.
	chunk := bytes.Repeat([]byte("S"), 16*1024)
	for sent := uint32(0); sent+uint32(len(chunk)) <= ack.DefaultWindow; sent += uint32(len(chunk)) {
		sendFrame(t, ws, 1, muxDATA, chunk)
	}
	// Соседний стрим обязан отвечать сразу.
	t0 := time.Now()
	sendFrame(t, ws, 2, muxDATA, []byte("ping"))
	if got := expectFrame(t, ws, 2, muxDATA, 2*time.Second); string(got) != "ping" {
		t.Fatalf("эхо соседа: %q", got)
	}
	if time.Since(t0) > time.Second {
		t.Fatalf("сосед ждал %s — HOL-блокировка на месте", time.Since(t0))
	}
}

// --- CLOSE в pending отменяет дозвон, зомби нет -----------------------------

func TestV2_CloseWhilePendingCancelsDial(t *testing.T) {
	m := withMemEvents(t)
	prev := sessionDialFn
	sessionDialFn = func(ctx context.Context, network, addr string) (net.Conn, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	t.Cleanup(func() { sessionDialFn = prev })
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, _ := dialV2(t, url, id, priv, "r-82")
	before := liveStreams.Load()
	sendFrame(t, ws, 7, muxCONNECT, connectPayload(tgTarget, 443))
	sendFrame(t, ws, 7, muxCLOSE, nil)
	if !m.wait("stream_close", 1, 2*time.Second) {
		t.Fatal("нет stream_close после CLOSE в pending")
	}
	if r := m.byEv("stream_close")[0].Reason; r != "peer_close" {
		t.Fatalf("reason=%q", r)
	}
	if liveStreams.Load() != before {
		t.Fatalf("liveStreams=%d, было %d — зомби", liveStreams.Load(), before)
	}
}

// --- REPLACED: CONNECT на занятый id закрывает старый с причиной -----------

func TestV2_ReplacedStreamGetsReason(t *testing.T) {
	startFakeDC(t, echoDC)
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, _ := dialV2(t, url, id, priv, "r-82")
	sendFrame(t, ws, 3, muxCONNECT, connectPayload(tgTarget, 443))
	expectFrame(t, ws, 3, muxCONNECT_OK, 2*time.Second)
	sendFrame(t, ws, 3, muxCONNECT, connectPayload(tgTarget, 443))
	p := expectFrame(t, ws, 3, muxCLOSE, 2*time.Second)
	if r, _ := decodeClose(p); r != rReplaced {
		t.Fatalf("причина %d, ожидалась REPLACED", r)
	}
	expectFrame(t, ws, 3, muxCONNECT_OK, 2*time.Second)
}

// --- Окно c→r: превышение кредита = CLOSE(PROTOCOL) ---------------------------

func TestV2_WindowOverrunIsProtocolError(t *testing.T) {
	startFakeDC(t, echoDC)
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, ack := dialV2(t, url, id, priv, "r-82")
	sendFrame(t, ws, 1, muxCONNECT, connectPayload(tgTarget, 80)) // чёрная дыра: WINDOW не придёт
	expectFrame(t, ws, 1, muxCONNECT_OK, 2*time.Second)
	chunk := bytes.Repeat([]byte("x"), 32*1024)
	for sent := uint32(0); sent <= ack.DefaultWindow+uint32(len(chunk)); sent += uint32(len(chunk)) {
		sendFrame(t, ws, 1, muxDATA, chunk)
	}
	p := expectFrame(t, ws, 1, muxCLOSE, 3*time.Second)
	if r, _ := decodeClose(p); r != rProtocol {
		t.Fatalf("причина %d, ожидалась PROTOCOL", r)
	}
}

// --- Окно r→c: релей не читает DC без кредита, WINDOW открывает -------------
//
// «DC» на синхронном pipe: его Write завершается ровно тогда, когда релей
// прочитал байты, поэтому progress — это точное число прочитанного.

func TestV2_RelayHonoursClientCredit(t *testing.T) {
	startFakeDC(t, echoDC)
	var progress atomic.Int64
	pipeDC = func(c net.Conn) {
		defer c.Close()
		chunk := bytes.Repeat([]byte("D"), 4096)
		for i := 0; i < 3*(*defaultWindow)/4096; i++ { // втрое больше окна: релей обязан остановиться
			if _, err := c.Write(chunk); err != nil {
				return
			}
			progress.Add(int64(len(chunk)))
		}
	}
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, ack := dialV2(t, url, id, priv, "r-82")
	window := int64(ack.DefaultWindow)
	sendFrame(t, ws, 1, muxCONNECT, connectPayload(tgTarget, 80))
	expectFrame(t, ws, 1, muxCONNECT_OK, 2*time.Second)

	var got int64
	for got < window {
		got += int64(len(expectFrame(t, ws, 1, muxDATA, 2*time.Second)))
	}
	if got != window {
		t.Fatalf("до WINDOW получено %d, окно %d", got, window)
	}
	// Релей обязан остановиться ровно на окне: прогресс DC не растёт.
	time.Sleep(300 * time.Millisecond)
	if p := progress.Load(); p != window {
		t.Fatalf("релей прочитал у DC %d байт при окне %d", p, window)
	}
	sendFrame(t, ws, 1, muxWINDOW, encodeWindow(uint32(window)))
	for got < 2*window {
		got += int64(len(expectFrame(t, ws, 1, muxDATA, 2*time.Second)))
	}
	if got != 2*window {
		t.Fatalf("после WINDOW получено %d, ожидалось %d", got, 2*window)
	}
}

// --- Причина отказа авторизации доходит до клиента ---------------------------

func TestV2_AuthFailureIsExplicit(t *testing.T) {
	url := startRelay(t)
	ws := dialWS(t, url)
	h := append([]byte{protoVersion2, 4}, "r-82"...)
	h = append(h, 0, 0, 0, 0)
	sendFrame(t, ws, 0, muxHELLO, h)
	expectFrame(t, ws, 0, muxHELLO_ACK, 2*time.Second)
	sendFrame(t, ws, 0, muxAUTHID, make([]byte, 104)) // нули: nonce не тот, установки нет
	p := expectFrame(t, ws, 0, muxINFO, 2*time.Second)
	k, arg, _, _ := decodeInfo(p)
	if k != infoGoodbye || byte(arg) != rAuthFailed {
		t.Fatalf("ожидался GOODBYE(AUTH_FAILED), получено kind=%d arg=%d", k, arg)
	}
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := ws.ReadMessage(); err == nil || !strings.Contains(err.Error(), "1008") {
		t.Fatalf("ожидался WS Close 1008, получено %v", err)
	}
}

// --- Неизвестный тип кадра на стриме в v2 = CLOSE(PROTOCOL) -----------------

func TestV2_UnknownFrameTypeClosesStream(t *testing.T) {
	startFakeDC(t, echoDC)
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, _ := dialV2(t, url, id, priv, "r-82")
	sendFrame(t, ws, 1, muxCONNECT, connectPayload(tgTarget, 443))
	expectFrame(t, ws, 1, muxCONNECT_OK, 2*time.Second)
	sendFrame(t, ws, 1, 0x7f, nil)
	p := expectFrame(t, ws, 1, muxCLOSE, 2*time.Second)
	if r, _ := decodeClose(p); r != rProtocol {
		t.Fatalf("причина %d", r)
	}
}

// --- Троттлинг строк сохранён ------------------------------------------------

func TestNoisy_ThreeLinesThenCounter(t *testing.T) {
	m := withMemEvents(t)
	buf := &syncBuffer{}
	prev := log.Writer()
	log.SetOutput(buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, _ := dialV2(t, url, id, priv, "r-82")
	for i := 1; i <= 8; i++ {
		sendFrame(t, ws, uint16(i), muxCONNECT, connectPayload("37.193.146.91", 1443))
		expectFrame(t, ws, uint16(i), muxCONNECT_FAIL, 2*time.Second)
	}
	if n := strings.Count(buf.String(), "rejected non-Telegram"); n != 3 {
		t.Fatalf("строк %d, ожидалось 3", n)
	}
	if !m.wait("dial_fail", 8, time.Second) {
		t.Fatal("dial_fail должно быть 8")
	}
	ws.Close()
	if !m.wait("session_close", 1, 2*time.Second) || !strings.Contains(m.byEv("session_close")[0].Detail, "rejected_non_tg=8") {
		t.Fatalf("detail: %+v", m.byEv("session_close"))
	}
}

// --- Причина закрытия сессии по таймауту чтения ------------------------------

func TestSession_ReadTimeoutReason(t *testing.T) {
	if testing.Short() {
		t.Skip("ждёт настоящий таймаут чтения")
	}
	m := withMemEvents(t)
	prev := *authReadTimeout
	*authReadTimeout = 300 * time.Millisecond
	t.Cleanup(func() { *authReadTimeout = prev })
	url := startRelay(t)
	ws := dialWS(t, url)
	defer ws.Close()
	if !m.wait("session_close", 1, 3*time.Second) {
		t.Fatal("нет session_close после таймаута")
	}
	if r := m.byEv("session_close")[0].Reason; !strings.HasPrefix(r, "auth_read_err") {
		t.Fatalf("reason=%q", r)
	}
}

// syncBuffer — буфер лога под замком: сессии пишут в него из своих горутин.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// Роутер без работающего NTP: часы врут на 31,6 ч (полевой случай 02–04.09.2026,
// установка 7059f2d2 — 2526 отказов и ни одной сессии за двое суток). В v2 от
// повтора защищает nonce сервера, поэтому вход разрешён, а расхождение уходит
// клиенту советом ПОСЛЕ AUTH_OK — иначе клиент r-82.x счёл бы INFO отказом.
func TestV2_BadClockAuthenticatesAndGetsAdvice(t *testing.T) {
	startFakeDC(t, echoDC)
	url := startRelay(t)
	id, priv := testInstall(t)
	ws := dialWS(t, url)
	handshakeV2Over(t, ws, id, priv, "r-82.2", time.Now().Unix()-113755) // AUTH_OK внутри
	p := expectFrame(t, ws, 0, muxINFO, 2*time.Second)
	k, arg, _, err := decodeInfo(p)
	if err != nil || k != infoClockSkew {
		t.Fatalf("ожидался совет INFO CLOCK_SKEW, получено kind=%d err=%v", k, err)
	}
	if s := int32(arg); s > -113000 || s < -114500 {
		t.Fatalf("в совете расхождение %+d с, ожидалось около -113755", s)
	}
	// Сессия жива и работает: обычный CONNECT проходит.
	sendFrame(t, ws, 1, muxCONNECT, connectPayload(tgTarget, 80))
	expectFrame(t, ws, 1, muxCONNECT_OK, 2*time.Second)
}

// Часы в допуске — никакого совета, только AUTH_OK и тишина на стриме 0.
func TestV2_GoodClockNoAdvice(t *testing.T) {
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, _ := dialV2(t, url, id, priv, "r-82.2")
	ws.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if _, msg, err := ws.ReadMessage(); err == nil {
		sid, mt, _, _ := decodeFrame(msg)
		t.Fatalf("после AUTH_OK пришёл лишний кадр sid=%d type=0x%02x", sid, mt)
	}
}
