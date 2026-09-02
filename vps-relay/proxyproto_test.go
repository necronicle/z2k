package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"net"
	"strings"
	"testing"
	"time"
)

func TestProxyHeaderV1(t *testing.T) {
	r := bufio.NewReader(strings.NewReader("PROXY TCP4 46.146.27.195 213.176.74.63 53694 443\r\nGET"))
	a, err := parseProxyHeader(r)
	if err != nil || a == nil || a.String() != "46.146.27.195:53694" {
		t.Fatalf("v1: %v %v", a, err)
	}
	rest, _ := r.Peek(3)
	if string(rest) != "GET" {
		t.Fatalf("после заголовка должен остаться payload: %q", rest)
	}
	if a, err := parseProxyHeader(bufio.NewReader(strings.NewReader("PROXY UNKNOWN\r\n"))); err != nil || a != nil {
		t.Fatal("UNKNOWN = адрес не подменяется, не ошибка")
	}
}

func TestProxyHeaderV2(t *testing.T) {
	var b bytes.Buffer
	b.Write(proxyV2Sig)
	b.WriteByte(0x21) // v2, PROXY
	b.WriteByte(0x11) // TCP over IPv4
	_ = binary.Write(&b, binary.BigEndian, uint16(12))
	b.Write([]byte{88, 87, 93, 11, 213, 176, 74, 63})
	_ = binary.Write(&b, binary.BigEndian, uint16(57082))
	_ = binary.Write(&b, binary.BigEndian, uint16(443))
	b.WriteString("payload")
	r := bufio.NewReader(&b)
	a, err := parseProxyHeader(r)
	if err != nil || a == nil || a.String() != "88.87.93.11:57082" {
		t.Fatalf("v2: %v %v", a, err)
	}
	rest, _ := r.Peek(7)
	if string(rest) != "payload" {
		t.Fatalf("payload потерян: %q", rest)
	}
}

func TestProxyHeaderGarbageAndTimeout(t *testing.T) {
	if _, err := parseProxyHeader(bufio.NewReader(strings.NewReader("GET / HTTP/1.1\r\n"))); err == nil {
		t.Fatal("не-PROXY принят")
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	pl := newProxyListener(ln)
	pl.headerTimeout = 200 * time.Millisecond
	done := make(chan struct{})
	go func() {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err == nil {
			<-done
			c.Close()
		}
	}()
	// Accept вернёт ошибку только когда слушатель закрыт: молчащий клиент
	// отбрасывается внутри, а следующего клиента нет. Проверяем через
	// закрытие слушателя после таймаута.
	go func() { time.Sleep(600 * time.Millisecond); ln.Close() }()
	_, err = pl.Accept()
	close(done)
	if err == nil {
		t.Fatal("молчащий клиент без заголовка принят")
	}
}

func TestProxyListenerEndToEnd(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	pl := newProxyListener(ln)
	go func() {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			return
		}
		c.Write([]byte("PROXY TCP4 10.9.8.7 127.0.0.1 1234 8445\r\nhello"))
		time.Sleep(100 * time.Millisecond)
		c.Close()
	}()
	c, err := pl.Accept()
	if err != nil {
		t.Fatal(err)
	}
	if c.RemoteAddr().String() != "10.9.8.7:1234" {
		t.Fatalf("RemoteAddr=%s", c.RemoteAddr())
	}
	buf := make([]byte, 5)
	if _, err := c.Read(buf); err != nil || string(buf) != "hello" {
		t.Fatalf("payload: %q %v", buf, err)
	}
}

func TestReusePortTwice(t *testing.T) {
	a, err := listenReusePort("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := listenReusePort("tcp", a.Addr().String())
	if err != nil {
		t.Skipf("reuseport на этой ОС недоступен: %v", err)
	}
	b.Close()
}
