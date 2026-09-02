package main

import (
	"testing"
	"time"
)

func TestByteQueue_CapAndOrder(t *testing.T) {
	q := newByteQueue(10)
	if !q.push([]byte("aaaa")) || !q.push([]byte("bbbb")) {
		t.Fatal("8 из 10 байт должны войти")
	}
	if q.push([]byte("ccc")) {
		t.Fatal("11 байт сверх cap приняты")
	}
	if q.queued() != 8 {
		t.Fatalf("queued=%d", q.queued())
	}
	f, ok := q.pop()
	if !ok || string(f) != "aaaa" {
		t.Fatal("FIFO нарушен")
	}
	if !q.push([]byte("ccc")) {
		t.Fatal("после pop место должно освободиться")
	}
}

func TestByteQueue_WaitAndClose(t *testing.T) {
	q := newByteQueue(100)
	done := make(chan struct{})
	got := make(chan bool, 1)
	go func() { got <- q.wait(done) }()
	select {
	case <-got:
		t.Fatal("wait вернулся на пустой очереди")
	case <-time.After(50 * time.Millisecond):
	}
	q.push([]byte("x"))
	if !<-got {
		t.Fatal("wait обязан вернуть true после push")
	}
	q.close()
	if q.push([]byte("y")) || q.wait(done) {
		t.Fatal("после close push=false, wait=false")
	}
}

func TestByteQueue_WaitCancelledByDone(t *testing.T) {
	q := newByteQueue(100)
	done := make(chan struct{})
	got := make(chan bool, 1)
	go func() { got <- q.wait(done) }()
	close(done)
	select {
	case v := <-got:
		if v {
			t.Fatal("wait после done обязан вернуть false")
		}
	case <-time.After(time.Second):
		t.Fatal("wait не проснулся по done")
	}
}

func TestMemBudget(t *testing.T) {
	b := newMemBudget(1000)
	b.add(350)
	if b.over() {
		t.Fatal("350 < 400 не over")
	}
	b.add(100)
	if !b.over() || b.belowLow() {
		t.Fatal("450 > 400 over; не ниже 300")
	}
	b.add(-200)
	if !b.belowLow() {
		t.Fatal("250 < 300")
	}
	z := newMemBudget(0)
	z.add(1 << 40)
	if z.over() {
		t.Fatal("нулевой лимит = без бюджета")
	}
}
