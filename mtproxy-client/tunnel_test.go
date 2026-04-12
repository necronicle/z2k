package main

import (
	"bytes"
	"context"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func TestEncodeDecodeFrame(t *testing.T) {
	cases := []struct {
		id      uint16
		msgType byte
		payload []byte
	}{
		{0, muxAUTH, bytes.Repeat([]byte{0xAA}, 32)},
		{1, muxCONNECT, []byte{1, 10, 0, 0, 1, 0x01, 0xBB}},
		{65535, muxDATA, []byte("hello")},
		{7, muxCLOSE, nil},
		{42, muxCONNECT_OK, nil},
		{42, muxCONNECT_FAIL, nil},
	}
	for _, c := range cases {
		frame := encodeMuxFrame(c.id, c.msgType, c.payload)
		decoded, err := decodeMuxFrame(frame)
		if err != nil {
			t.Fatalf("decode failed for %+v: %v", c, err)
		}
		if decoded.StreamID != c.id || decoded.MsgType != c.msgType {
			t.Errorf("header mismatch: got id=%d type=0x%02x want id=%d type=0x%02x",
				decoded.StreamID, decoded.MsgType, c.id, c.msgType)
		}
		if !bytes.Equal(decoded.Payload, c.payload) && !(len(c.payload) == 0 && len(decoded.Payload) == 0) {
			t.Errorf("payload mismatch: got %v want %v", decoded.Payload, c.payload)
		}
	}
}

func TestDecodeFrameTooShort(t *testing.T) {
	if _, err := decodeMuxFrame([]byte{0, 1}); err == nil {
		t.Error("expected error for short frame")
	}
}

// newTestSession builds a session with a nil websocket — safe as long as the
// test doesn't invoke writePump/readPump/dial. Suitable for state-machine tests.
func newTestSession(tc *tunnelClient) *session {
	return &session{
		tc:      tc,
		idx:     0,
		writeCh: make(chan []byte, 256),
		pingReq: make(chan struct{}, 1),
		done:    make(chan struct{}),
		streams: make(map[uint16]*stream),
		cfGate:  make(chan struct{}, cfLimit),
	}
}

// newDummyTCP returns a *net.TCPConn that isn't actually connected to anything
// useful — it's a pipe side that can be closed. Only the Close path is exercised.
func newDummyTCP(t *testing.T) *net.TCPConn {
	t.Helper()
	// Create a loopback listener + dial to get a real *net.TCPConn.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	type result struct {
		c *net.TCPConn
		e error
	}
	ch := make(chan result, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			ch <- result{nil, err}
			return
		}
		ch <- result{c.(*net.TCPConn), nil}
	}()

	d := net.Dialer{Timeout: 2 * time.Second}
	conn, err := d.DialContext(context.Background(), "tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	_ = conn.Close() // we only need the server-side conn alive for Close()
	r := <-ch
	if r.e != nil {
		t.Fatalf("accept: %v", r.e)
	}
	return r.c
}

func TestStreamHalfCloseStateMachine(t *testing.T) {
	tc := &tunnelClient{}
	s := newTestSession(tc)

	// Acquire one gate slot to simulate a live stream.
	s.cfGate <- struct{}{}

	conn := newDummyTCP(t)
	st := &stream{id: 42, conn: conn, state: stOpen}
	s.mu.Lock()
	s.streams[42] = st
	s.mu.Unlock()

	// local close first
	s.localClose(st)

	s.mu.Lock()
	if !st.localClosed {
		t.Error("localClosed should be true after localClose")
	}
	if st.remoteClosed {
		t.Error("remoteClosed should still be false")
	}
	if _, exists := s.streams[42]; !exists {
		t.Error("stream should still be in map during half-close grace")
	}
	if st.gateReleased {
		t.Error("gate should not be released while remoteClosed is false")
	}
	s.mu.Unlock()

	// now remote close arrives → both closed → should be purged and gate released
	s.remoteClose(st)

	s.mu.Lock()
	if _, exists := s.streams[42]; exists {
		t.Error("stream should be removed when both sides closed")
	}
	if !st.gateReleased {
		t.Error("gate should be released when both sides closed")
	}
	s.mu.Unlock()

	// gate slot must be free again
	select {
	case s.cfGate <- struct{}{}:
	default:
		t.Error("gate slot not released — all 6 occupied")
	}

	// Verify localClose is idempotent (must not panic, must not double-release).
	s.localClose(st)
	s.remoteClose(st)
}

func TestLocalCloseSendsCloseFrame(t *testing.T) {
	tc := &tunnelClient{}
	s := newTestSession(tc)
	s.cfGate <- struct{}{}

	conn := newDummyTCP(t)
	st := &stream{id: 7, conn: conn, state: stOpen}
	s.mu.Lock()
	s.streams[7] = st
	s.mu.Unlock()

	go s.localClose(st)

	// Drain the frame from writeCh within a timeout.
	select {
	case frame := <-s.writeCh:
		decoded, err := decodeMuxFrame(frame)
		if err != nil {
			t.Fatalf("decode: %v", err)
		}
		if decoded.StreamID != 7 || decoded.MsgType != muxCLOSE {
			t.Errorf("want CLOSE on stream 7, got id=%d type=0x%02x", decoded.StreamID, decoded.MsgType)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no CLOSE frame enqueued within 2s")
	}
}

func TestRemoteCloseDoesNotSendCloseFrame(t *testing.T) {
	tc := &tunnelClient{}
	s := newTestSession(tc)
	s.cfGate <- struct{}{}

	conn := newDummyTCP(t)
	st := &stream{id: 9, conn: conn, state: stOpen}
	s.mu.Lock()
	s.streams[9] = st
	s.mu.Unlock()

	s.remoteClose(st)

	select {
	case f := <-s.writeCh:
		t.Errorf("remoteClose should not enqueue anything, got %v", f)
	case <-time.After(200 * time.Millisecond):
		// ok
	}
}

func TestGrimReaperGrace(t *testing.T) {
	tc := &tunnelClient{}
	s := newTestSession(tc)
	s.cfGate <- struct{}{}

	conn := newDummyTCP(t)
	st := &stream{
		id:            11,
		conn:          conn,
		state:         stOpen,
		localClosed:   true,
		closeDeadline: time.Now().Add(-1 * time.Second), // already expired
	}
	s.mu.Lock()
	s.streams[11] = st
	s.mu.Unlock()

	// Run one reaper sweep manually (grimReaper uses a 1s ticker; call its body).
	now := time.Now()
	s.mu.Lock()
	for id, cur := range s.streams {
		fullyClosed := cur.localClosed && cur.remoteClosed
		graceExpired := !cur.closeDeadline.IsZero() && now.After(cur.closeDeadline)
		if fullyClosed || graceExpired {
			if !cur.gateReleased {
				cur.gateReleased = true
				select {
				case <-s.cfGate:
				default:
				}
			}
			delete(s.streams, id)
		}
	}
	s.mu.Unlock()

	s.mu.Lock()
	_, exists := s.streams[11]
	s.mu.Unlock()
	if exists {
		t.Error("stream should have been reaped after grace expiry")
	}
	if !st.gateReleased {
		t.Error("gate should be released by reaper")
	}
}

func TestCfGateExactlyOnceRelease(t *testing.T) {
	tc := &tunnelClient{}
	s := newTestSession(tc)

	// Fill all 6 slots with fake streams; close them all via different paths
	// and confirm we still have exactly 6 free slots at the end.
	streams := make([]*stream, cfLimit)
	for i := 0; i < cfLimit; i++ {
		s.cfGate <- struct{}{}
		conn := newDummyTCP(t)
		st := &stream{id: uint16(i + 1), conn: conn, state: stOpen}
		s.mu.Lock()
		s.streams[st.id] = st
		s.mu.Unlock()
		streams[i] = st
	}

	// Mix of close paths: both sides closed through different orderings.
	s.localClose(streams[0])
	s.remoteClose(streams[0])

	s.remoteClose(streams[1])
	s.localClose(streams[1])

	// Idempotent double-call followed by the other side.
	s.localClose(streams[2])
	s.localClose(streams[2])
	s.remoteClose(streams[2])

	s.remoteClose(streams[3])
	s.remoteClose(streams[3])
	s.localClose(streams[3])

	// Last two: simulate reaper path (half-closed, grace expired).
	for _, st := range streams[4:] {
		s.mu.Lock()
		st.localClosed = true
		st.closeDeadline = time.Now().Add(-1 * time.Second)
		s.mu.Unlock()
	}
	now := time.Now()
	s.mu.Lock()
	for id, cur := range s.streams {
		if !cur.closeDeadline.IsZero() && now.After(cur.closeDeadline) {
			if !cur.gateReleased {
				cur.gateReleased = true
				select {
				case <-s.cfGate:
				default:
				}
			}
			delete(s.streams, id)
		}
	}
	s.mu.Unlock()

	// Drain all 6 slots to confirm exactly 6 were released.
	freed := 0
	for i := 0; i < cfLimit+2; i++ {
		select {
		case s.cfGate <- struct{}{}:
			freed++
		default:
			break
		}
	}
	if freed != cfLimit {
		t.Errorf("expected exactly %d free slots after cleanup, got %d", cfLimit, freed)
	}
}

// Sanity check that atomic pointer swap works as tunnelClient expects.
func TestSessionPointerSwap(t *testing.T) {
	var p atomic.Pointer[session]
	if p.Load() != nil {
		t.Error("initial should be nil")
	}
	s1 := &session{}
	p.Store(s1)
	if p.Load() != s1 {
		t.Error("load mismatch")
	}
	p.Store(nil)
	if p.Load() != nil {
		t.Error("nil store failed")
	}
}
