package main

import "sync/atomic"

// memBudget — сумма байт во всех очередях всех стримов (спека §3.3). Пороги:
// high = 40 % лимита, low = 30 %. Лимит 0 = бюджета нет (тесты, dev).
type memBudget struct {
	used atomic.Int64
	high int64
	low  int64
}

var budget = newMemBudget(0)

func newMemBudget(limitBytes int64) *memBudget {
	return &memBudget{high: limitBytes * 40 / 100, low: limitBytes * 30 / 100}
}

func (b *memBudget) add(n int64)    { b.used.Add(n) }
func (b *memBudget) over() bool     { return b.high > 0 && b.used.Load() > b.high }
func (b *memBudget) belowLow() bool { return b.high == 0 || b.used.Load() < b.low }
