package main

import (
	"bufio"
	"crypto/tls"
	"io"
	"net"
	"testing"
	"time"
)

func TestFailedTLSCleanupHonorsRequestBudget(t *testing.T) {
	raw, peer := net.Pipe()
	defer raw.Close()
	defer peer.Close()
	cfg := selfSignedTLSConfig(t)
	cfg.MaxVersion = tls.VersionTLS12
	server := tls.Server(peer, cfg)
	done := make(chan struct{})
	release := make(chan struct{})
	defer func() { close(release); raw.Close(); peer.Close(); <-done }()
	raw.SetDeadline(time.Now().Add(2 * time.Second))
	peer.SetDeadline(time.Now().Add(2 * time.Second))
	go func() {
		defer close(done)
		if err := server.Handshake(); err != nil {
			return
		}
		b := make([]byte, 5)
		io.ReadFull(server, b)
		<-release
	}()
	up := tls.Client(raw, &tls.Config{InsecureSkipVerify: true, MaxVersion: tls.VersionTLS12})
	if err := up.Handshake(); err != nil {
		t.Fatal(err)
	}
	raw.SetDeadline(time.Time{})
	peer.SetDeadline(time.Time{})
	oldOpen, oldWait, oldFirst := openTunnelFn, *pickWaitTO, *firstByteTO
	defer func() { openTunnelFn = oldOpen; *pickWaitTO = oldWait; *firstByteTO = oldFirst }()
	*pickWaitTO = 40 * time.Millisecond
	*firstByteTO = time.Second
	openTunnelFn = func(string, string, time.Time) (net.Conn, *bufio.Reader, bool, bool) {
		return up, bufio.NewReaderSize(up, bufSize), true, true
	}
	start := time.Now()
	c, _ := dialUpstream(&pool{live: []string{"fixture"}}, "rutracker.org", []byte("hello"))
	elapsed := time.Since(start)
	if c != nil {
		t.Fatal("unexpected success")
	}
	if elapsed > 250*time.Millisecond {
		t.Fatalf("40ms upstream budget took %s due to TLS cleanup", elapsed)
	}
}

func TestRemainingBudgetMustNotDemoteHealthyNode(t *testing.T) {
	cfg := selfSignedTLSConfig(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		raw, e := ln.Accept()
		if e != nil {
			return
		}
		defer raw.Close()
		raw.SetDeadline(time.Now().Add(time.Second))
		time.Sleep(40 * time.Millisecond)
		c := tls.Server(raw, cfg)
		if c.Handshake() != nil {
			return
		}
		br := bufio.NewReader(c)
		for {
			line, e := br.ReadString('\n')
			if e != nil {
				return
			}
			if line == "\r\n" {
				break
			}
		}
		io.WriteString(c, "HTTP/1.1 200 OK\r\n\r\n")
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	oldOpen, oldWait, oldDial, oldPort := openTunnelFn, *pickWaitTO, *dialTO, *proxyPort
	defer func() {
		openTunnelFn = oldOpen
		*pickWaitTO = oldWait
		*dialTO = oldDial
		*proxyPort = oldPort
		ln.Close()
		<-done
	}()
	*proxyPort = port
	*pickWaitTO = 100 * time.Millisecond
	*dialTO = time.Second
	openTunnelFn = func(ip, target string, deadline time.Time) (net.Conn, *bufio.Reader, bool, bool) {
		if ip == "slow-target" {
			time.Sleep(85 * time.Millisecond)
			return nil, nil, false, true
		}
		return openTunnelUntil(ip, target, deadline)
	}
	p := &pool{live: []string{"127.0.0.1", "slow-target"}}
	dialUpstream(p, "dead-target", []byte("hello"))
	if p.liveCount() != 2 {
		t.Fatalf("healthy 40ms TLS node demoted after receiving only 15ms remaining request budget: %v", liveSet(p))
	}
}
