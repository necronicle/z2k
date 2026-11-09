package gvsub

// Проверка адреса мимо нашего обхода: TCP на 443 и TLS с нейтральным именем.
// Блок, который лечит подмена, режет ответ сервера: соединение встаёт,
// ClientHello уходит, ServerHello не приходит. Нейтральное имя нужно, чтобы
// не попасть под отдельный блок по имени googlevideo — он есть всегда и
// снимается плечами z2k, а не подменой.

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"net/netip"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/sockmark"
)

// Verdict — состояние адреса.
type Verdict int

const (
	Unknown Verdict = iota
	Good            // сервер ответил на TLS
	Bad             // TCP есть, ответа на TLS нет
	Dead            // TCP не открылся: адрес не в работе, подменять нечего
)

func (v Verdict) String() string {
	switch v {
	case Good:
		return "good"
	case Bad:
		return "bad"
	case Dead:
		return "dead"
	}
	return "unknown"
}

// Значения из замеров на линии Марка 09.11.2026: TCP к узлам Google 0,07–0,12 с,
// TLS с нейтральным именем у рабочих адресов 0,17–0,69 с (максимум — через
// переадресацию с Mac). Потолок — с запасом над наблюдаемым максимумом.
const (
	TCPTimeout = 1 * time.Second
	TLSTimeout = 1 * time.Second
	ProbeSNI   = "example.com"
)

// Checker проверяет адрес.
type Checker interface {
	Check(ctx context.Context, addr netip.Addr) Verdict
}

// NetChecker — настоящая проверка по сети с меткой обхода.
type NetChecker struct{}

func (NetChecker) Check(ctx context.Context, addr netip.Addr) Verdict {
	d := net.Dialer{Control: sockmark.Control, Timeout: TCPTimeout}
	c, err := d.DialContext(ctx, "tcp", netip.AddrPortFrom(addr, 443).String())
	if err != nil {
		return Dead
	}
	// Закрывать сбросом: после проверки плохого адреса обычное закрытие висело
	// в FIN_WAIT/CLOSING ~3,5 мин, и таких сокетов роутера к Google копилось
	// сотни (сбор 10.11.2026: 775 за 45 мин).
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetLinger(0)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(TLSTimeout))
	tc := tls.Client(c, &tls.Config{ServerName: ProbeSNI, InsecureSkipVerify: true}) // #nosec G402 -- проверяем только факт ответа
	err = tc.HandshakeContext(ctx)
	if err == nil {
		return Good
	}
	// Ответ пришёл, но не понравился (alert, неожиданная запись) — сервер жив.
	var ae tls.AlertError
	var re tls.RecordHeaderError
	if errors.As(err, &ae) || errors.As(err, &re) {
		return Good
	}
	return Bad
}
