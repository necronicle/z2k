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

	// ProveEvery — как часто пробовать доказать НЕДОКАЗАННЫЙ транспорт.
	// Отдельно от Doubt (30 с) намеренно: пока транспорт не доказан, лестница
	// стоит на нём, а человек без WARP. Ждать полминуты на каждой мёртвой
	// ступени значит превратить перебор в вечность. Ноль — 3 с.
	ProveEvery time.Duration

	lastRx, lastTx uint64
	rxLastMoved    time.Time // когда rx в последний раз рос (или первый замер)
	lastProbe      time.Time
	fails          int
	seen           bool
	proven         bool
}

// Proven — доказал ли ЭТОТ транспорт, что несёт трафик до конца.
//
// ГОТОВНОСТЬ ОБЯЗАНА БЫТЬ ДОКАЗАННОЙ. Shell-контракт всегда говорил
// «0 — ready (туннель доказанно несёт трафик)», а монитор возвращал Alive на
// первом же опросе, до единой пробы: достаточно было, что сессия установлена.
// Маршруты поднимались на непроверенном туннеле, и там, где транспорт не
// возит — MASQUE на линии, где его глушат, — трафик уходил в чёрную дыру.
//
// Чинить это выбором транспортов в коде нельзя, и попытка стоила поля: h2
// сняли из лестницы по замеру на ОДНОЙ линии, а у тех, чей WG-диапазон
// заблокирован целиком, он был единственным рабочим — WARP отключился совсем.
// Решать обязан замер на КАЖДОМ роутере: держим в лестнице всё, а готовность
// даём только тому, что доказало себя здесь.
func (m *Monitor) Proven() bool { return m.proven }

// Reset — после переоткрытия транспорта счётчики начинаются заново.
func (m *Monitor) Reset() {
	*m = Monitor{Probe: m.Probe, Doubt: m.Doubt, Fails: m.Fails, ProveEvery: m.ProveEvery}
}

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
	}
	if !m.proven {
		// Сессия есть — но донесёт ли она до другого конца, ещё не известно.
		// Пока не доказано, Alive не отдаём ни при каких счётчиках: у
		// чёрной дыры rx тоже растёт, пока сервер здоровается.
		return m.probe(ctx, now, src)
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
	every := m.Doubt
	if !m.proven {
		every = m.ProveEvery
		if every <= 0 {
			every = 3 * time.Second
		}
	}
	if !m.lastProbe.IsZero() && now.Sub(m.lastProbe) < every {
		if m.fails >= m.Fails {
			return Dead
		}
		return Doubtful
	}
	m.lastProbe = now
	if err := m.Probe(ctx, src); err == nil {
		m.fails = 0
		m.rxLastMoved = now
		m.proven = true
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
