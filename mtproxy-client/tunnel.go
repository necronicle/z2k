package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

// Mux message types
const (
	muxCONNECT      = 0x01
	muxDATA         = 0x02
	muxCLOSE        = 0x03
	muxCONNECT_OK   = 0x04
	muxCONNECT_FAIL = 0x05
)

const (
	wsPingInterval = 30 * time.Second
	wsReadTimeout  = 90 * time.Second
)

// Минимальный интервал между повторными регистрациями. Прежняя константа
// idFallbackCooldownSec (300 с) описывала, сколько клиент СИДИТ на общем
// секрете; теперь он туда не уходит вовсе, и смысл интервала другой — не чаще
// какого срока мы дёргаем /register, у которого своё ограничение частоты.
const reRegMinIntervalSec = 120

// Address types for CONNECT payload
const (
	addrIPv4 = 1
	addrIPv6 = 4
)

// muxFrame represents a decoded mux protocol frame.
type muxFrame struct {
	StreamID uint16
	MsgType  byte
	Payload  []byte
}

// encodeMuxFrame encodes a mux frame into binary wire format.
func encodeMuxFrame(streamID uint16, msgType byte, payload []byte) []byte {
	buf := make([]byte, 3+len(payload))
	binary.BigEndian.PutUint16(buf[0:2], streamID)
	buf[2] = msgType
	if len(payload) > 0 {
		copy(buf[3:], payload)
	}
	return buf
}

// decodeMuxFrame decodes a binary mux frame from wire format.
func decodeMuxFrame(data []byte) (muxFrame, error) {
	if len(data) < 3 {
		return muxFrame{}, fmt.Errorf("mux frame too short: %d bytes", len(data))
	}
	return muxFrame{
		StreamID: binary.BigEndian.Uint16(data[0:2]),
		MsgType:  data[2],
		Payload:  data[3:],
	}, nil
}

// encodeConnectPayload creates the CONNECT payload: [addr_type][addr][port]
func encodeConnectPayload(ip net.IP, port int) []byte {
	v4 := ip.To4()
	if v4 != nil {
		buf := make([]byte, 1+4+2)
		buf[0] = addrIPv4
		copy(buf[1:5], v4)
		binary.BigEndian.PutUint16(buf[5:7], uint16(port))
		return buf
	}
	buf := make([]byte, 1+16+2)
	buf[0] = addrIPv6
	copy(buf[1:17], ip.To16())
	binary.BigEndian.PutUint16(buf[17:19], uint16(port))
	return buf
}

// computeAuthHMAC computes the HMAC-SHA256 of the shared secret (keyed by itself).
func computeAuthHMAC(secret string) []byte {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(secret))
	return mac.Sum(nil)
}

func configureWSKeepalive(ws *websocket.Conn) {
	ws.SetReadLimit(2 * 1024 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(wsReadTimeout))
	ws.SetPongHandler(func(string) error {
		_ = ws.SetReadDeadline(time.Now().Add(wsReadTimeout))
		return nil
	})
	ws.SetPingHandler(func(data string) error {
		_ = ws.SetReadDeadline(time.Now().Add(wsReadTimeout))
		return ws.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(5*time.Second))
	})
}

// tunnelClient manages the multiplexed WS tunnel.
type tunnelClient struct {
	tunnelURL    string
	tunnelSecret string

	// Атомарный, а не голый указатель: фоновая перерегистрация ПЕРЕПИСЫВАЕТ
	// личность (перевыпуск после 409), а читают её горутины подключений на
	// каждой аутентификации. Голое поле здесь — гонка данных.
	identity     atomic.Pointer[relayIdentity]
	registerURL  string
	useID        atomic.Bool  // send per-install auth (set true after a successful register)
	idFailStreak atomic.Int32 // consecutive fast deaths while on per-install auth
	reRegAt      atomic.Int64 // unix sec последней повторной регистрации (защита от долбёжки)
	reRegBusy    atomic.Bool  // повторная регистрация уже идёт

	ws         *websocket.Conn
	writer     *wsWriter
	streams    sync.Map // uint16 → *tunnelStream
	nextID     atomic.Uint32
	mu         sync.Mutex    // protects ws/writer replacement during reconnect
	connectSem chan struct{} // limits concurrent in-flight CONNECTs — 6 keeps SYN rate under TG DC burst threshold
	ctx        context.Context
	cancel     context.CancelFunc
}

type tunnelStream struct {
	id          uint16
	conn        *net.TCPConn
	client      *tunnelClient
	closeOnce   sync.Once
	remoteClose atomic.Bool // set when relay initiated the close
}

func (s *tunnelStream) close() {
	s.closeOnce.Do(func() {
		s.conn.Close()
		s.client.streams.Delete(s.id)
		// Only send CLOSE if we initiated the close (not the relay)
		if !s.remoteClose.Load() {
			s.client.mu.Lock()
			w := s.client.writer
			s.client.mu.Unlock()
			if w != nil {
				frame := encodeMuxFrame(s.id, muxCLOSE, nil)
				w.WriteMessage(websocket.BinaryMessage, frame)
			}
		}
		// Release connection semaphore
		<-connSemaphore
	})
}

// connectTunnelWS establishes a WebSocket connection to the tunnel relay.
// triggerReRegister перерегистрирует установку, когда персональная
// аутентификация раз за разом обрывается. Это замена прежнему откату на общий
// секрет: откат релей всё равно отвергает, а перерегистрация чинит настоящую
// причину — отсутствие нашего публичного ключа у релея.
//
// Не блокирует цикл переподключения: попытка уходит в фон. Не чаще раза в
// reRegMinIntervalSec — иначе клиент в петле быстрых обрывов превратился бы в
// генератор запросов к /register, а он ограничен по частоте на стороне релея и
// начал бы отвечать отказом уже законно.
// registerOnce регистрирует текущую личность и САМА разбирает случай, когда
// идентификатор уже занят другим ключом.
//
// Раньше этот разбор жил только в фоновой перерегистрации, а она вызывается
// исключительно из ветки для уже зарегистрированных (useID). То есть установка,
// у которой ключ разошёлся с реестром ДО первой удачной регистрации, получала
// 409 в стартовом цикле, повторяла с тем же ключом бесконечно и не могла выйти
// из этого никогда: перевыпуск был написан, но недостижим. Туннель при этом не
// поднимался вовсе — релей требует персональную аутентификацию.
//
// Возвращает true, если после вызова личность зарегистрирована.
// identityLoop добывает личность и регистрирует её, не сдаваясь.
//
// Два отказа раньше были окончательными и лечились только перезапуском
// процесса. Первый: если loadOrMintIdentity не смогла записать файл (диск
// переполнен, /opt в режиме только чтения), клиент писал строку в лог и не
// пробовал больше НИКОГДА — а значит навсегда оставался на общем секрете,
// который релей с включённым требованием персональной аутентификации не
// принимает. Второй: 409 в стартовом цикле повторялся с тем же ключом до
// бесконечности, потому что перевыпуск был доступен только уже
// зарегистрировавшимся (см. registerOnce).
//
// Пауза растёт до 5 минут, а не до получаса: пока регистрация не прошла,
// туннель не работает вообще, и длинная пауза — это прямое время простоя
// телеграма у человека, а не экономия запросов к релею.
func (tc *tunnelClient) identityLoop() {
	for attempt := 0; ; attempt++ {
		if tc.identity.Load() == nil {
			if id, err := loadOrMintIdentity(*relayIDFile); err != nil {
				log.Printf("[tunnel] личность недоступна (%v) — повторю попытку", err)
			} else {
				tc.identity.Store(id)
			}
		}
		if tc.identity.Load() != nil && tc.registerOnce() {
			tc.useID.Store(true)
			if id := tc.identity.Load(); id != nil {
				log.Printf("[tunnel] registered identity %s — using per-install auth", id.InstallID)
			}
			return
		}
		wait := 30 * time.Second
		if attempt >= 20 {
			wait = 5 * time.Minute
		}
		select {
		case <-time.After(wait):
		case <-tc.ctx.Done():
			return
		}
	}
}

func (tc *tunnelClient) registerOnce() bool {
	id := tc.identity.Load()
	if id == nil || tc.registerURL == "" {
		return false
	}
	err := id.register(tc.registerURL, *tunnelSecret)
	if err == nil {
		return true
	}
	// Идентификатор занят другим ключом — повторять с тем же бесполезно, ответ
	// не изменится никогда. Перевыпускаем личность целиком.
	if errors.Is(err, errIdentityTaken) {
		log.Printf("[tunnel] идентификатор %s занят другим ключом — перевыпускаю личность", id.InstallID)
		fresh, mErr := reMintIdentity(*relayIDFile)
		if mErr != nil {
			log.Printf("[tunnel] перевыпуск личности не удался: %v", mErr)
			return false
		}
		tc.identity.Store(fresh)
		if rErr := fresh.register(tc.registerURL, *tunnelSecret); rErr != nil {
			log.Printf("[tunnel] регистрация новой личности не удалась: %v", rErr)
			return false
		}
		log.Printf("[tunnel] новая личность зарегистрирована (%s)", fresh.InstallID)
		return true
	}
	// Пишем ВСЕГДА, а не только под -v. Это единственная строка, отличающая
	// «нас не пускают» от «сети нет», и без неё второй экземпляр туннеля
	// (S97z2k-http-tunnel, запускается без -v) молчал о своих отказах вовсе.
	log.Printf("[tunnel] регистрация не удалась: %v", err)
	return false
}

func (tc *tunnelClient) triggerReRegister() {
	if tc.identity.Load() == nil || tc.registerURL == "" {
		return
	}
	now := time.Now().Unix()
	if last := tc.reRegAt.Load(); last > 0 && now-last < reRegMinIntervalSec {
		return
	}
	if !tc.reRegBusy.CompareAndSwap(false, true) {
		return
	}
	tc.reRegAt.Store(now)
	go func() {
		defer tc.reRegBusy.Store(false)
		if tc.registerOnce() {
			if id := tc.identity.Load(); id != nil {
				log.Printf("[tunnel] установка перерегистрирована (%s)", id.InstallID)
			}
		}
	}()
}

func (tc *tunnelClient) connectTunnelWS() (*websocket.Conn, error) {
	// БЕЗ ЗАРЕГИСТРИРОВАННОЙ ЛИЧНОСТИ НЕ ЛЕЗЕМ НА РЕЛЕЙ ВОВСЕ.
	//
	// Здесь был фоллбэк: пока личность не зарегистрирована, клиент
	// подключался общим секретом (кадр типа 0x00) — с комментарием «релей
	// принимает обе схемы, это не переключение». Комментарий устарел и стоил
	// людям связи: релей давно поднят с --require-per-install и общий секрет
	// отвергает наглухо. useID же выставляется только ПОСЛЕ успешной
	// регистрации. Получался вечный цикл «подключился → отвергнут →
	// переподключился» по разу в 48 секунд, и телеграм у человека не
	// поднимался никогда. На релее это выглядело как 5900 отказов в час с 78
	// адресов при одной успешной регистрации за тот же час (issue #34).
	//
	// Проверяем ДО набора номера, а не перед отправкой кадра: иначе на каждую
	// попытку тратится TCP+TLS до релея, и его лог забивают пары
	// «WS accepted / WS closed dur=0s». Регистрацией занимается identityLoop
	// параллельно, ему нужно только время.
	id := tc.identity.Load()
	if id == nil || !tc.useID.Load() {
		return nil, errNotRegistered
	}

	dialer := websocket.Dialer{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: false,
		},
		HandshakeTimeout:  10 * time.Second,
		ReadBufferSize:    256 * 1024,
		WriteBufferSize:   256 * 1024,
		EnableCompression: false,
		NetDial: func(network, addr string) (net.Conn, error) {
			// Force IPv4 — IPv6 to Cloudflare is unstable on some ISPs
			conn, err := net.DialTimeout("tcp4", addr, 10*time.Second)
			if err != nil {
				return nil, err
			}
			if tcpConn, ok := conn.(*net.TCPConn); ok {
				tcpConn.SetNoDelay(true)
			}
			return conn, nil
		},
	}

	headers := http.Header{}
	ws, _, err := dialer.Dial(tc.tunnelURL, headers)
	if err != nil {
		return nil, fmt.Errorf("WS dial %s: %w", tc.tunnelURL, err)
	}
	configureWSKeepalive(ws)

	authFrame := encodeMuxFrame(0x0000, 0x06, id.authPayload())
	ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := ws.WriteMessage(websocket.BinaryMessage, authFrame); err != nil {
		ws.Close()
		return nil, fmt.Errorf("WS auth write: %w", err)
	}

	log.Printf("[tunnel] connected to %s", tc.tunnelURL)
	return ws, nil
}

// closeAllStreams closes all active tunnel streams.
func (tc *tunnelClient) closeAllStreams() {
	tc.streams.Range(func(key, value any) bool {
		stream := value.(*tunnelStream)
		stream.close()
		return true
	})
}

// readLoop reads mux frames from the WS and dispatches to streams.
func (tc *tunnelClient) readLoop(ws *websocket.Conn) {
	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			if *verbose {
				log.Printf("[tunnel] WS read error: %v", err)
			}
			return
		}

		frame, err := decodeMuxFrame(msg)
		if err != nil {
			if *verbose {
				log.Printf("[tunnel] bad mux frame: %v", err)
			}
			continue
		}

		val, ok := tc.streams.Load(frame.StreamID)
		if !ok {
			if *verbose && frame.MsgType != muxCLOSE {
				log.Printf("[tunnel] frame for unknown stream %d (type=0x%02x)", frame.StreamID, frame.MsgType)
			}
			continue
		}
		stream := val.(*tunnelStream)

		switch frame.MsgType {
		case muxDATA:
			stream.conn.SetDeadline(time.Now().Add(*connTimeout))
			if _, err := stream.conn.Write(frame.Payload); err != nil {
				if *verbose {
					log.Printf("[tunnel] stream %d write error: %v", frame.StreamID, err)
				}
				stream.close()
			}

		case muxCLOSE:
			if *verbose {
				log.Printf("[tunnel] stream %d closed by relay", frame.StreamID)
			}
			stream.remoteClose.Store(true)
			stream.close()

		case muxCONNECT_OK:
			select {
			case <-tc.connectSem:
			default:
			}
			if *verbose {
				log.Printf("[tunnel] stream %d CONNECT_OK", frame.StreamID)
			}
			go tc.streamReadLoop(stream)

		case muxCONNECT_FAIL:
			select {
			case <-tc.connectSem:
			default:
			}
			log.Printf("[tunnel] stream %d CONNECT_FAIL", frame.StreamID)
			stream.remoteClose.Store(true)
			stream.close()

		default:
			if *verbose {
				log.Printf("[tunnel] stream %d unknown msg type 0x%02x", frame.StreamID, frame.MsgType)
			}
		}
	}
}

// streamReadLoop reads from a TCP client and sends DATA frames over WS.
func (tc *tunnelClient) streamReadLoop(stream *tunnelStream) {
	defer stream.close()

	buf := make([]byte, 64*1024)

	for {
		n, err := stream.conn.Read(buf)
		if n > 0 {
			stream.conn.SetDeadline(time.Now().Add(*connTimeout))
			frame := encodeMuxFrame(stream.id, muxDATA, buf[:n])
			tc.mu.Lock()
			w := tc.writer
			tc.mu.Unlock()
			if w == nil {
				return
			}
			if werr := w.WriteMessage(websocket.BinaryMessage, frame); werr != nil {
				if *verbose {
					log.Printf("[tunnel] stream %d WS write error: %v", stream.id, werr)
				}
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// run manages the persistent WS connection with auto-reconnect.
func (tc *tunnelClient) run() {
	consecutiveFails := 0

	for {
		select {
		case <-tc.ctx.Done():
			return
		default:
		}

		ws, err := tc.connectTunnelWS()
		if errors.Is(err, errNotRegistered) {
			// Не отказ сети и не повод раскручивать backoff до двух минут:
			// регистрацией занимается identityLoop, ему нужно время. Ждём
			// коротко и молча — жаловаться тут не на что, а вот стучаться в
			// релей схемой, которую он отвергает, было бы вредно и ему, и нам.
			select {
			case <-time.After(5 * time.Second):
				continue
			case <-tc.ctx.Done():
				return
			}
		}
		if err != nil {
			consecutiveFails++
			backoff := 3 * time.Second
			if consecutiveFails >= 10 {
				backoff = 120 * time.Second
			} else if consecutiveFails >= 5 {
				backoff = 30 * time.Second
			} else if consecutiveFails >= 3 {
				backoff = 10 * time.Second
			}
			log.Printf("[tunnel] connect failed (%d in a row, backoff %s): %v", consecutiveFails, backoff, err)
			select {
			case <-time.After(backoff):
				continue
			case <-tc.ctx.Done():
				return
			}
		}

		tc.mu.Lock()
		tc.ws = ws
		tc.writer = &wsWriter{ws: ws}
		tc.mu.Unlock()

		connectedAt := time.Now()

		// Keepalive: ping every 30s (symmetric with server)
		wsDone := make(chan struct{})
		pingDone := make(chan struct{})
		go func() {
			defer close(pingDone)
			ticker := time.NewTicker(wsPingInterval)
			defer ticker.Stop()
			for {
				select {
				case <-ticker.C:
					tc.mu.Lock()
					w := tc.writer
					tc.mu.Unlock()
					if w != nil {
						if err := w.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
							if *verbose {
								log.Printf("[tunnel] ping failed: %v", err)
							}
							_ = ws.Close()
							return
						}
					}
				case <-wsDone:
					return
				case <-tc.ctx.Done():
					return
				}
			}
		}()

		// Read loop blocks until WS disconnects
		tc.readLoop(ws)

		// WS disconnected — signal ping goroutine, close all streams
		close(wsDone)
		log.Printf("[tunnel] WS disconnected, closing all streams")
		tc.mu.Lock()
		tc.ws = nil
		tc.writer = nil
		tc.mu.Unlock()
		ws.Close()
		tc.closeAllStreams()

		// Drain connect semaphore — pending CONNECTs died with the WS
		for {
			select {
			case <-tc.connectSem:
			default:
				goto drained
			}
		}
	drained:

		// Wait for ping goroutine
		select {
		case <-pingDone:
		case <-time.After(2 * time.Second):
		}

		// Per-install auth keeps dying fast → RE-REGISTER, never fall back.
		//
		// Раньше здесь стоял откат на общий секрет с расчётом, что релей принимает
		// оба способа. С включением --require-per-install это перестало быть правдой:
		// релей общий секрет отвергает молча, и откат превращал поправимую заминку в
		// гарантированные 300 секунд мёртвого туннеля — после которых всё
		// повторялось. Полевой симптом: «WS died too fast (5 in a row)» без конца.
		//
		// Причина быстрых обрывов на персональной аутентификации почти всегда одна:
		// у релея нет нашего публичного ключа (регистрация не доехала, реестр
		// потерян, ключ перевыпущен). Это лечится повторной регистрацией, а не
		// сменой способа входа. Поэтому мы остаёмся на персональной аутентификации
		// и заново регистрируемся в фоне.
		if tc.useID.Load() {
			if time.Since(connectedAt) < 8*time.Second {
				if tc.idFailStreak.Add(1) >= 3 {
					tc.idFailStreak.Store(0)
					tc.triggerReRegister()
				}
			} else {
				tc.idFailStreak.Store(0)
			}
		}

		// If WS lived < 5 seconds, it's a rapid death — increase backoff
		if time.Since(connectedAt) < 5*time.Second {
			consecutiveFails++
			backoff := 3 * time.Second
			if consecutiveFails >= 10 {
				backoff = 120 * time.Second
			} else if consecutiveFails >= 5 {
				backoff = 30 * time.Second
			} else if consecutiveFails >= 3 {
				backoff = 10 * time.Second
			}
			log.Printf("[tunnel] WS died too fast (%d in a row), backing off %s", consecutiveFails, backoff)
			select {
			case <-time.After(backoff):
			case <-tc.ctx.Done():
				return
			}
		} else {
			consecutiveFails = 0
			select {
			case <-tc.ctx.Done():
				return
			case <-time.After(1 * time.Second):
				log.Printf("[tunnel] reconnecting...")
			}
		}
	}
}

// handleTunnelConn handles a new TCP connection by creating a mux stream.
func (tc *tunnelClient) handleTunnelConn(clientConn *net.TCPConn) {
	clientConn.SetNoDelay(true)
	clientConn.SetDeadline(time.Now().Add(*connTimeout))

	// Get original destination (iptables REDIRECT)
	origIP, origPort, err := getOriginalDst(clientConn)
	if err != nil {
		if *verbose {
			log.Printf("[tunnel] getOriginalDst failed: %v", err)
		}
		clientConn.Close()
		<-connSemaphore
		return
	}

	// Allocate stream ID — skip IDs still in use (prevents wrap-around collision)
	var streamID uint16
	idFound := false
	for i := 0; i < 100; i++ {
		rawID := tc.nextID.Add(1)
		streamID = uint16(rawID%65535) + 1
		if _, exists := tc.streams.Load(streamID); !exists {
			idFound = true
			break
		}
	}
	if !idFound {
		log.Printf("[tunnel] stream ID exhaustion, dropping connection from %s", clientConn.RemoteAddr())
		clientConn.Close()
		<-connSemaphore
		return
	}

	tc.mu.Lock()
	w := tc.writer
	tc.mu.Unlock()
	if w == nil {
		if *verbose {
			log.Printf("[tunnel] no WS connection, dropping stream %d", streamID)
		}
		clientConn.Close()
		<-connSemaphore
		return
	}

	stream := &tunnelStream{
		id:     streamID,
		conn:   clientConn,
		client: tc,
	}
	tc.streams.Store(streamID, stream)

	if *verbose {
		log.Printf("[tunnel] stream %d: %s -> %s:%d", streamID, clientConn.RemoteAddr(), origIP, origPort)
	}

	// Rate-limit concurrent in-flight CONNECTs — TG DC throttles SYN bursts from single IP
	select {
	case tc.connectSem <- struct{}{}:
	case <-time.After(10 * time.Second):
		log.Printf("[tunnel] stream %d CONNECT throttled (timeout)", streamID)
		stream.remoteClose.Store(true)
		stream.close()
		return
	}

	// Send CONNECT frame
	connectPayload := encodeConnectPayload(origIP, origPort)
	frame := encodeMuxFrame(streamID, muxCONNECT, connectPayload)
	if err := w.WriteMessage(websocket.BinaryMessage, frame); err != nil {
		<-tc.connectSem
		log.Printf("[tunnel] stream %d CONNECT write error: %v", streamID, err)
		stream.remoteClose.Store(true)
		stream.close()
		return
	}

	// streamReadLoop starts when CONNECT_OK is received in readLoop
}

// runTunnel is the entry point for tunnel mode.
func runTunnel() error {
	if *tunnelURL == "" {
		return fmt.Errorf("--tunnel-url is required in tunnel mode")
	}
	if *tunnelSecret == "" {
		return fmt.Errorf("--tunnel-secret is required in tunnel mode")
	}

	connSemaphore = make(chan struct{}, *maxConns)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", *listenAddr, err)
	}

	log.Printf("[tunnel] listening on %s, relay=%s", *listenAddr, *tunnelURL)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tc := &tunnelClient{
		tunnelURL:    *tunnelURL,
		tunnelSecret: *tunnelSecret,
		connectSem:   make(chan struct{}, 6),
	}
	tc.ctx, tc.cancel = context.WithCancel(ctx)

	// Stage B: load/mint the per-install identity and register it in the
	// background. Until registration succeeds the client authenticates with the
	// shared secret (dual-accepted by the relay), so a relay without /register or
	// a transient registration failure never blocks the tunnel.
	tc.registerURL = deriveRegisterURL(*tunnelURL)
	go tc.identityLoop()

	go tc.run()

	// Wait for first WS connection before accepting TCP — prevents burst
	// of connections hitting a not-yet-ready Worker
	for i := 0; i < 100; i++ {
		tc.mu.Lock()
		w := tc.writer
		tc.mu.Unlock()
		if w != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	go func() {
		<-ctx.Done()
		log.Println("[tunnel] shutting down...")
		tc.cancel()
		ln.Close()
	}()

	// Бэкофф для временных ошибок Accept. Голый `continue` здесь означал
	// 100% CPU навсегда: при EMFILE (кончились дескрипторы) или после того,
	// как слушатель закрыт не через ctx (net.ErrClosed), ошибка постоянна, и
	// цикл крутится вхолостую на роутере, где это единственное ядро. Своего
	// watchdog'а у клиента нет, в логе тоже ничего — ровно тот класс, что уже
	// проживал 141 час CPU незамеченным у осиротевшего спиннера.
	var acceptDelay time.Duration
	const acceptDelayMax = 1 * time.Second

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				log.Println("[tunnel] stopped")
				return nil
			default:
			}
			// Закрытый слушатель — состояние необратимое: повторять Accept
			// бессмысленно, супервизор поднимет процесс заново.
			if errors.Is(err, net.ErrClosed) {
				log.Printf("[tunnel] listener closed: %v — stopping accept loop", err)
				return err
			}
			// Временное (EMFILE/ENFILE/ECONNABORTED) — отступаем с удвоением,
			// давая дескрипторам освободиться, и обязательно пишем в лог.
			if acceptDelay == 0 {
				acceptDelay = 5 * time.Millisecond
			} else {
				acceptDelay *= 2
			}
			if acceptDelay > acceptDelayMax {
				acceptDelay = acceptDelayMax
			}
			log.Printf("[tunnel] accept error: %v — retrying in %v", err, acceptDelay)
			select {
			case <-time.After(acceptDelay):
			case <-ctx.Done():
				log.Println("[tunnel] stopped")
				return nil
			}
			continue
		}
		acceptDelay = 0
		tcpConn, ok := conn.(*net.TCPConn)
		if !ok {
			conn.Close()
			continue
		}

		select {
		case connSemaphore <- struct{}{}:
			go tc.handleTunnelConn(tcpConn)
		default:
			if *verbose {
				log.Printf("[tunnel] max connections reached, rejecting %s", conn.RemoteAddr())
			}
			conn.Close()
		}
	}
}
