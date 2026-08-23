// Package health — живость туннеля: доказана, не предположена.
//
// Три сигнала, от дешёвого к дорогому:
//  1. Health() транспорта каждую секунду — бесплатно. rx растёт → жив.
//  2. tx растёт, rx стоит дольше Doubt → одна e2e-проба через TUN (GET
//     1.1.1.1/cdn-cgi/trace с адреса туннеля, warp=on). Арбитр, не тик.
//  3. Fails проб подряд → Dead; дальше решает лестница.
//
// Простой без трафика — не смерть: если никто не шлёт, нечему и приходить.
package health

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
)

// Verdict — вердикт монитора.
type Verdict int

const (
	Alive Verdict = iota
	Doubtful
	Dead
)

func (v Verdict) String() string {
	switch v {
	case Alive:
		return "alive"
	case Doubtful:
		return "doubtful"
	default:
		return "dead"
	}
}

// Prober — сквозная проверка через интерфейс туннеля iface.
type Prober func(ctx context.Context, iface string) error

// Monitor хранит состояние между вызовами Assess.
type Monitor struct {
	Probe Prober
	Doubt time.Duration // сколько терпеть «tx растёт, rx нет» до пробы
	Fails int           // сколько провалов проб подряд = Dead

	lastRx, lastTx uint64
	rxLastMoved    time.Time // когда rx в последний раз рос (или первый замер)
	lastProbe      time.Time
	fails          int
	seen           bool
}

// Reset — после переоткрытия транспорта счётчики начинаются заново.
func (m *Monitor) Reset() { *m = Monitor{Probe: m.Probe, Doubt: m.Doubt, Fails: m.Fails} }

// Assess оценивает снимок h в момент now. src — имя интерфейса для пробы.
func (m *Monitor) Assess(ctx context.Context, h transport.Health, now time.Time, src string) Verdict {
	if h.Err != nil {
		return Dead
	}
	if !h.Connected {
		// Сессии нет — сомнение сразу, без ожидания Doubt; проба всё равно
		// нужна (WG после idle переподнимается первым же пакетом).
		return m.probe(ctx, now, src)
	}
	if !m.seen {
		m.seen = true
		m.lastRx, m.lastTx = h.Rx, h.Tx
		m.rxLastMoved = now
		return Alive
	}
	rxGrew := h.Rx > m.lastRx
	txGrew := h.Tx > m.lastTx
	m.lastRx, m.lastTx = h.Rx, h.Tx
	if rxGrew {
		m.rxLastMoved = now
		m.fails = 0
		return Alive
	}
	if !txGrew {
		return Alive // простой
	}
	if now.Sub(m.rxLastMoved) < m.Doubt {
		return Alive
	}
	return m.probe(ctx, now, src)
}

// probe зовёт Prober не чаще раза в Doubt и считает провалы.
func (m *Monitor) probe(ctx context.Context, now time.Time, src string) Verdict {
	if m.Probe == nil {
		return Doubtful
	}
	if !m.lastProbe.IsZero() && now.Sub(m.lastProbe) < m.Doubt {
		if m.fails >= m.Fails {
			return Dead
		}
		return Doubtful
	}
	m.lastProbe = now
	if err := m.Probe(ctx, src); err == nil {
		m.fails = 0
		m.rxLastMoved = now
		return Alive
	}
	m.fails++
	if m.fails >= m.Fails {
		return Dead
	}
	return Doubtful
}

// TraceProbe — Prober по умолчанию: GET https://1.1.1.1/cdn-cgi/trace,
// сокет привязан к интерфейсу туннеля (SO_BINDTODEVICE — как `curl
// --interface`), поэтому проба не может утечь в WAN и дать ложный «жив».
// Адресом, не именем: DNS-сбой не должен выглядеть смертью туннеля.
func TraceProbe(timeout time.Duration) Prober {
	return func(ctx context.Context, iface string) error {
		if iface == "" {
			return errors.New("probe: no interface")
		}
		d := &net.Dialer{Timeout: timeout, Control: bindToDevice(iface)}
		c := &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				DialContext:       d.DialContext,
				TLSClientConfig:   &tls.Config{ServerName: "one.one.one.one"},
				DisableKeepAlives: true,
			},
		}
		req, err := http.NewRequestWithContext(ctx, "GET", "https://1.1.1.1/cdn-cgi/trace", nil)
		if err != nil {
			return err
		}
		resp, err := c.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if err != nil {
			return err
		}
		if !strings.Contains(string(body), "warp=on") {
			return errors.New("probe: warp=off")
		}
		return nil
	}
}
