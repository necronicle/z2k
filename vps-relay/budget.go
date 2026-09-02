package main

import (
	"fmt"
	"math"
	"runtime/debug"
	"sync/atomic"
	"time"
)

// memBudget — сумма байт во всех очередях всех стримов (спека §3.3). Пороги:
// high = 40 % лимита, low = 30 %. Лимит 0 = бюджета нет (тесты, dev).
type memBudget struct {
	used atomic.Int64
	high atomic.Int64
	low  atomic.Int64
}

var budget = newMemBudget(0)

func newMemBudget(limitBytes int64) *memBudget {
	b := &memBudget{}
	b.setLimit(limitBytes)
	return b
}

// setLimit — пороги от лимита; вызывается из main() и из тестов, поэтому
// поля атомарные: сессии читают их из своих горутин.
func (b *memBudget) setLimit(limitBytes int64) {
	b.high.Store(limitBytes * 40 / 100)
	b.low.Store(limitBytes * 30 / 100)
}

func (b *memBudget) add(n int64) { b.used.Add(n) }
func (b *memBudget) over() bool  { h := b.high.Load(); return h > 0 && b.used.Load() > h }
func (b *memBudget) belowLow() bool {
	return b.high.Load() == 0 || b.used.Load() < b.low.Load()
}

// memLimitBytes — действующий GOMEMLIMIT; без лимита бюджет выключен.
func memLimitBytes() int64 {
	lim := debug.SetMemoryLimit(-1)
	if lim <= 0 || lim == math.MaxInt64 {
		return 0
	}
	return lim
}

// trimLoop режет самый тяжёлый стрим на узле, пока сумма очередей выше
// low. Сессии не трогаются никогда (спека §3.3).
func (b *memBudget) trimLoop(every time.Duration, stop <-chan struct{}) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tk.C:
		}
		if !b.over() {
			continue
		}
		var trimmed int
		for !b.belowLow() {
			var victim *stream
			var max int64
			forEachSession(func(s *session) {
				if st, q := s.heaviestStream(); st != nil && q > max {
					victim, max = st, q
				}
			})
			if victim == nil {
				break
			}
			victim.abort(rQueueLimit, "бюджет памяти узла")
			trimmed++
		}
		if trimmed > 0 {
			metrics.add("relay_budget_trims_total", "", int64(trimmed))
			emitEvent(Event{Ev: "budget_trim", Reason: "queue_limit", Streams: trimmed,
				Detail: fmt.Sprintf("used=%d high=%d", b.used.Load(), b.high.Load())})
		}
	}
}
