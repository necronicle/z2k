package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

// PROXY protocol v1/v2 (haproxy). nginx stream с proxy_protocol on шлёт v1;
// v2 поддержан на случай смены прокси. Заголовок читается с дедлайном:
// сканер, открывший TCP и молчащий, не должен держать горутину.
var proxyV2Sig = []byte{0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A}

type proxyListener struct {
	net.Listener
	headerTimeout time.Duration
}

func newProxyListener(l net.Listener) *proxyListener {
	return &proxyListener{Listener: l, headerTimeout: 5 * time.Second}
}

type proxyConn struct {
	net.Conn
	r      *bufio.Reader
	remote net.Addr
}

func (c *proxyConn) Read(b []byte) (int, error) { return c.r.Read(b) }

func (c *proxyConn) RemoteAddr() net.Addr {
	if c.remote != nil {
		return c.remote
	}
	return c.Conn.RemoteAddr()
}

func (p *proxyListener) Accept() (net.Conn, error) {
	for {
		c, err := p.Listener.Accept()
		if err != nil {
			return nil, err
		}
		_ = c.SetReadDeadline(time.Now().Add(p.headerTimeout))
		r := bufio.NewReaderSize(c, 4096)
		src, perr := parseProxyHeader(r)
		_ = c.SetReadDeadline(time.Time{})
		if perr != nil {
			_ = c.Close()
			metrics.inc("relay_proxyproto_errors_total", "")
			continue // чужой стук — не отдаём его серверу
		}
		return &proxyConn{Conn: c, r: r, remote: src}, nil
	}
}

// parseProxyHeader читает заголовок из r; nil, nil — «PROXY UNKNOWN» или
// v2 LOCAL (адрес оставить как есть).
func parseProxyHeader(r *bufio.Reader) (net.Addr, error) {
	head, err := r.Peek(12)
	if err != nil && len(head) < 6 {
		return nil, fmt.Errorf("proxy header: %w", err)
	}
	if len(head) >= 12 && string(head) == string(proxyV2Sig) {
		return parseProxyV2(r)
	}
	if len(head) >= 6 && string(head[:6]) == "PROXY " {
		return parseProxyV1(r)
	}
	return nil, errors.New("proxy header: не PROXY")
}

func parseProxyV1(r *bufio.Reader) (net.Addr, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return nil, fmt.Errorf("proxy v1: %w", err)
	}
	if len(line) > 108 || !strings.HasSuffix(line, "\r\n") {
		return nil, errors.New("proxy v1: плохая строка")
	}
	f := strings.Fields(strings.TrimSuffix(line, "\r\n"))
	if len(f) == 2 && f[1] == "UNKNOWN" {
		return nil, nil
	}
	if len(f) != 6 || (f[1] != "TCP4" && f[1] != "TCP6") {
		return nil, errors.New("proxy v1: неверные поля")
	}
	ip := net.ParseIP(f[2])
	port, perr := strconv.Atoi(f[4])
	if ip == nil || perr != nil || port < 0 || port > 65535 {
		return nil, errors.New("proxy v1: адрес источника")
	}
	return &net.TCPAddr{IP: ip, Port: port}, nil
}

func parseProxyV2(r *bufio.Reader) (net.Addr, error) {
	hdr := make([]byte, 16)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, fmt.Errorf("proxy v2: %w", err)
	}
	if hdr[12]>>4 != 2 {
		return nil, errors.New("proxy v2: версия")
	}
	cmd, fam := hdr[12]&0x0F, hdr[13]
	n := int(binary.BigEndian.Uint16(hdr[14:16]))
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, fmt.Errorf("proxy v2 body: %w", err)
	}
	if cmd == 0 { // LOCAL: проверка здоровья самого прокси
		return nil, nil
	}
	switch fam {
	case 0x11: // TCP/IPv4
		if n < 12 {
			return nil, errors.New("proxy v2: короткий v4")
		}
		return &net.TCPAddr{IP: net.IPv4(body[0], body[1], body[2], body[3]), Port: int(binary.BigEndian.Uint16(body[8:10]))}, nil
	case 0x21: // TCP/IPv6
		if n < 36 {
			return nil, errors.New("proxy v2: короткий v6")
		}
		return &net.TCPAddr{IP: net.IP(body[0:16]), Port: int(binary.BigEndian.Uint16(body[32:34]))}, nil
	}
	return nil, errors.New("proxy v2: семейство")
}
