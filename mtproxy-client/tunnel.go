package main

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
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

// tunnelClient manages the multiplexed WS tunnel.
type tunnelClient struct {
	tunnelURL    string
	tunnelSecret string

	ws         *websocket.Conn
	writer     *wsWriter
	streams    sync.Map     // uint16 → *tunnelStream
	nextID     atomic.Uint32
	mu         sync.Mutex   // protects ws/writer replacement during reconnect
	connectSem chan struct{} // limits concurrent CONNECT to CF Workers limit
	wsReady    chan struct{} // closed when WS is connected, recreated on disconnect
	ctx        context.Context
	cancel     context.CancelFunc
}

type tunnelStream struct {
	id        uint16
	conn      *net.TCPConn
	client    *tunnelClient
	origIP    net.IP // original destination IP (for re-CONNECT after reconnect)
	origPort  int    // original destination port
	closeOnce sync.Once
	upBytes   atomic.Int64
	downBytes atomic.Int64
	connected atomic.Bool // true after first CONNECT_OK
}

func (s *tunnelStream) close() {
	s.closeOnce.Do(func() {
		up := s.upBytes.Load()
		down := s.downBytes.Load()
		if *verbose {
			log.Printf("[tunnel] stream %d closed (up=%d down=%d)", s.id, up, down)
		}
		s.conn.Close()
		s.client.streams.Delete(s.id)
		s.client.mu.Lock()
		w := s.client.writer
		s.client.mu.Unlock()
		if w != nil {
			frame := encodeMuxFrame(s.id, muxCLOSE, nil)
			w.WriteMessage(websocket.BinaryMessage, frame)
		}
	})
}

// connectTunnelWS establishes a WebSocket connection to the tunnel relay.
func (tc *tunnelClient) connectTunnelWS() (*websocket.Conn, error) {
	dialer := websocket.Dialer{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: false,
		},
		HandshakeTimeout:  10 * time.Second,
		Subprotocols:      []string{"binary"},
		ReadBufferSize:    128 * 1024,
		WriteBufferSize:   128 * 1024,
		EnableCompression: true,
		NetDial: func(network, addr string) (net.Conn, error) {
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
	ws.SetReadLimit(2 * 1024 * 1024)

	// Send auth message: [0x00 0x00][0x00][hmac_32_bytes]
	authMAC := computeAuthHMAC(tc.tunnelSecret)
	authFrame := encodeMuxFrame(0x0000, 0x00, authMAC)
	ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := ws.WriteMessage(websocket.BinaryMessage, authFrame); err != nil {
		ws.Close()
		return nil, fmt.Errorf("WS auth write: %w", err)
	}

	log.Printf("[tunnel] connected to %s", tc.tunnelURL)
	return ws, nil
}

// reConnectStreams re-sends CONNECT for all surviving streams after WS reconnect.
func (tc *tunnelClient) reConnectStreams() {
	tc.mu.Lock()
	w := tc.writer
	tc.mu.Unlock()
	if w == nil {
		return
	}

	count := 0
	tc.streams.Range(func(key, value any) bool {
		stream := value.(*tunnelStream)
		stream.connected.Store(false)

		connectPayload := encodeConnectPayload(stream.origIP, stream.origPort)
		frame := encodeMuxFrame(stream.id, muxCONNECT, connectPayload)
		if err := w.WriteMessage(websocket.BinaryMessage, frame); err != nil {
			log.Printf("[tunnel] stream %d re-CONNECT write error: %v", stream.id, err)
			stream.close()
			return true
		}
		count++
		return true
	})
	if count > 0 {
		log.Printf("[tunnel] re-CONNECTed %d surviving streams", count)
	}
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

		// Any incoming message means WS is alive — extend read deadline
		ws.SetReadDeadline(time.Now().Add(120 * time.Second))

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
			stream.downBytes.Add(int64(len(frame.Payload)))
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
			stream.conn.Close()
			tc.streams.Delete(frame.StreamID)

		case muxCONNECT_OK:
			select {
			case <-tc.connectSem:
			default:
			}
			stream.connected.Store(true)
			if *verbose {
				log.Printf("[tunnel] stream %d CONNECT_OK", frame.StreamID)
			}

		case muxCONNECT_FAIL:
			select {
			case <-tc.connectSem:
			default:
			}
			log.Printf("[tunnel] stream %d CONNECT_FAIL", frame.StreamID)
			stream.conn.Close()
			tc.streams.Delete(frame.StreamID)

		default:
			if *verbose {
				log.Printf("[tunnel] stream %d unknown msg type 0x%02x", frame.StreamID, frame.MsgType)
			}
		}
	}
}

// streamReadLoop reads from a TCP client and sends DATA frames over WS.
// Survives WS reconnects: waits for writer to become available again.
func (tc *tunnelClient) streamReadLoop(stream *tunnelStream) {
	defer stream.close()

	reader := bufio.NewReaderSize(stream.conn, 64*1024)
	buf := make([]byte, 64*1024)

	for {
		n, err := reader.Read(buf)
		if n > 0 {
			stream.upBytes.Add(int64(n))
			stream.conn.SetDeadline(time.Now().Add(*connTimeout))
			frame := encodeMuxFrame(stream.id, muxDATA, buf[:n])

			// Wait for WS to be available (survives reconnect)
			for attempt := 0; attempt < 50; attempt++ {
				tc.mu.Lock()
				w := tc.writer
				tc.mu.Unlock()
				if w != nil {
					if werr := w.WriteMessage(websocket.BinaryMessage, frame); werr != nil {
						if *verbose {
							log.Printf("[tunnel] stream %d WS write error: %v", stream.id, werr)
						}
						// Write failed — WS probably just died, wait for reconnect
						time.Sleep(100 * time.Millisecond)
						continue
					}
					break // success
				}
				// No writer — WS is reconnecting, wait
				time.Sleep(100 * time.Millisecond)
			}
		}
		if err != nil {
			return
		}
	}
}

// run manages the persistent WS connection with auto-reconnect.
func (tc *tunnelClient) run() {
	for {
		select {
		case <-tc.ctx.Done():
			return
		default:
		}

		ws, err := tc.connectTunnelWS()
		if err != nil {
			log.Printf("[tunnel] connect failed: %v (retrying in 3s)", err)
			select {
			case <-time.After(3 * time.Second):
				continue
			case <-tc.ctx.Done():
				return
			}
		}

		tc.mu.Lock()
		tc.ws = ws
		tc.writer = &wsWriter{ws: ws}
		tc.mu.Unlock()

		// PongHandler: update read deadline when pong received
		ws.SetPongHandler(func(appData string) error {
			ws.SetReadDeadline(time.Now().Add(120 * time.Second))
			return nil
		})
		// Initial read deadline
		ws.SetReadDeadline(time.Now().Add(120 * time.Second))

		// Re-CONNECT surviving streams from previous WS session
		tc.reConnectStreams()

		// Keepalive: ping every 50s (CF kills idle WS after 100s)
		pingDone := make(chan struct{})
		go func() {
			defer close(pingDone)
			ticker := time.NewTicker(50 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ticker.C:
					tc.mu.Lock()
					w := tc.writer
					tc.mu.Unlock()
					if w != nil {
						w.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
					}
				case <-tc.ctx.Done():
					return
				}
			}
		}()

		// Read loop blocks until WS disconnects
		tc.readLoop(ws)

		// WS disconnected — DON'T close client TCP connections
		log.Printf("[tunnel] WS disconnected, keeping streams alive for reconnect")
		tc.mu.Lock()
		tc.ws = nil
		tc.writer = nil
		tc.mu.Unlock()
		ws.Close()

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

		select {
		case <-tc.ctx.Done():
			return
		case <-time.After(1 * time.Second):
			log.Printf("[tunnel] reconnecting...")
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
		return
	}

	// Allocate stream ID — skip IDs still in use (prevents wrap-around collision)
	var streamID uint16
	for i := 0; i < 100; i++ {
		rawID := tc.nextID.Add(1)
		streamID = uint16(rawID%65535) + 1
		if _, exists := tc.streams.Load(streamID); !exists {
			break
		}
	}

	// Wait up to 5s for WS to be ready (handles new connections during reconnect)
	tc.mu.Lock()
	w := tc.writer
	tc.mu.Unlock()
	if w == nil {
		for i := 0; i < 50; i++ {
			time.Sleep(100 * time.Millisecond)
			tc.mu.Lock()
			w = tc.writer
			tc.mu.Unlock()
			if w != nil {
				break
			}
		}
		if w == nil {
			if *verbose {
				log.Printf("[tunnel] no WS connection after waiting, dropping stream %d", streamID)
			}
			clientConn.Close()
			return
		}
	}

	stream := &tunnelStream{
		id:       streamID,
		conn:     clientConn,
		client:   tc,
		origIP:   origIP,
		origPort: origPort,
	}
	tc.streams.Store(streamID, stream)

	if *verbose {
		log.Printf("[tunnel] stream %d: %s -> %s:%d", streamID, clientConn.RemoteAddr(), origIP, origPort)
	}

	// Rate-limit concurrent CONNECTs to stay within CF Workers 6-connection limit
	select {
	case tc.connectSem <- struct{}{}:
	case <-time.After(10 * time.Second):
		log.Printf("[tunnel] stream %d CONNECT throttled (timeout)", streamID)
		stream.conn.Close()
		tc.streams.Delete(streamID)
		return
	}

	// Send CONNECT frame
	connectPayload := encodeConnectPayload(origIP, origPort)
	frame := encodeMuxFrame(streamID, muxCONNECT, connectPayload)
	if err := w.WriteMessage(websocket.BinaryMessage, frame); err != nil {
		<-tc.connectSem
		log.Printf("[tunnel] stream %d CONNECT write error: %v", streamID, err)
		stream.conn.Close()
		tc.streams.Delete(streamID)
		return
	}

	go tc.streamReadLoop(stream)
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

	go tc.run()

	go func() {
		<-ctx.Done()
		log.Println("[tunnel] shutting down...")
		tc.cancel()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				log.Println("[tunnel] stopped")
				return nil
			default:
				continue
			}
		}
		tcpConn, ok := conn.(*net.TCPConn)
		if !ok {
			conn.Close()
			continue
		}

		select {
		case connSemaphore <- struct{}{}:
			go func() {
				defer func() { <-connSemaphore }()
				tc.handleTunnelConn(tcpConn)
			}()
		default:
			if *verbose {
				log.Printf("[tunnel] max connections reached, rejecting %s", conn.RemoteAddr())
			}
			conn.Close()
		}
	}
}
