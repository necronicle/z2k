package main

import (
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
func (tc *tunnelClient) connectTunnelWS() (*websocket.Conn, error) {
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
			ticker := time.NewTicker(30 * time.Second)
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
			go tc.handleTunnelConn(tcpConn)
		default:
			if *verbose {
				log.Printf("[tunnel] max connections reached, rejecting %s", conn.RemoteAddr())
			}
			conn.Close()
		}
	}
}
