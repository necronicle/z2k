package main

import (
	"bufio"
	"crypto/tls"
	"io"
	"net"
	"testing"
	"time"
)

// The caller must bound a blocked ClientHello write, not just response reads.
func TestServerFlightBoundsBlockedHelloWrite(t *testing.T) {
	up, peer := net.Pipe()
	defer up.Close()
	defer peer.Close()
	old := *firstByteTO
	*firstByteTO = 40 * time.Millisecond
	defer func() { *firstByteTO = old }()
	done := make(chan bool, 1)
	go func() { done <- verifyFirstByte("fixture", up, bufio.NewReader(up), []byte("hello")) }()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("stalled peer accepted")
		}
	case <-time.After(300 * time.Millisecond):
		peer.Close()
		<-done
		t.Fatal("blocked hello write outlived first-byte budget")
	}
}

func incompleteCONNECTProxy(t *testing.T) string {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", selfSignedTLSConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(4 * time.Second))
		r := bufio.NewReader(c)
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			if line == "\r\n" {
				break
			}
		}
		io.WriteString(c, "HTTP/1.1 200 Connection established\r\nX-Test: partial\r\n")
		io.Copy(io.Discard, c)
	}()
	t.Cleanup(func() { ln.Close(); <-done })
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	return port
}
func TestOpenTunnelRejectsIncompleteCONNECTHeaders(t *testing.T) {
	port := incompleteCONNECTProxy(t)
	oldPort, oldTO := *proxyPort, *dialTO
	*proxyPort, *dialTO = port, 60*time.Millisecond
	defer func() { *proxyPort, *dialTO = oldPort, oldTO }()
	up, _, ok, reachable := openTunnel("127.0.0.1", "rutracker.org:443")
	if up != nil {
		up.Close()
	}
	if ok || up != nil || !reachable {
		t.Fatalf("incomplete headers accepted or healthy transport misclassified: ok=%v reachable=%v", ok, reachable)
	}
}
func TestRetryAbsoluteDeadlineIncludesCONNECT(t *testing.T) {
	port := incompleteCONNECTProxy(t)
	oldPort, oldDial, oldWait, oldFirst := *proxyPort, *dialTO, *pickWaitTO, *firstByteTO
	*proxyPort, *dialTO, *pickWaitTO, *firstByteTO = port, time.Second, 80*time.Millisecond, time.Second
	defer func() { *proxyPort, *dialTO, *pickWaitTO, *firstByteTO = oldPort, oldDial, oldWait, oldFirst }()
	p := &pool{live: []string{"127.0.0.1"}}
	start := time.Now()
	up, _ := dialUpstream(p, "rutracker.org", []byte("hello"))
	elapsed := time.Since(start)
	if up != nil {
		up.Close()
		t.Fatal("incomplete CONNECT accepted")
	}
	if elapsed > 400*time.Millisecond {
		t.Fatalf("80ms request budget overrun: %s", elapsed)
	}
}
