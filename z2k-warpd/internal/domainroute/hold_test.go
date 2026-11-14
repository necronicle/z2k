package domainroute

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Ответ отпускается после того, как разобран: адрес уже в наборе, когда
// устройство получает ответ и открывает соединение.
func TestHolderReleasesAfterHandlingInOrder(t *testing.T) {
	var mu sync.Mutex
	var events []string
	h := newHolder(func(p []byte) {
		mu.Lock()
		events = append(events, "handle "+string(p))
		mu.Unlock()
	}, time.Minute, 8)
	done := make(chan struct{}, 2)
	for _, p := range []string{"a", "b"} {
		p := p
		h.push([]byte(p), func() {
			mu.Lock()
			events = append(events, "release "+p)
			mu.Unlock()
			done <- struct{}{}
		})
	}
	<-done
	<-done
	h.stop()
	want := []string{"handle a", "release a", "handle b", "release b"}
	if len(events) != len(want) {
		t.Fatalf("events %v", events)
	}
	for i := range want {
		if events[i] != want[i] {
			t.Fatalf("events %v, want %v", events, want)
		}
	}
}

// Застрявшая запись в наборы не держит DNS дольше предела, и ответ
// отпускается ровно один раз.
func TestHolderReleasesByLimitOnce(t *testing.T) {
	block := make(chan struct{})
	h := newHolder(func([]byte) { <-block }, 20*time.Millisecond, 8)
	var n atomic.Int32
	released := make(chan struct{}, 1)
	start := time.Now()
	h.push([]byte("x"), func() { n.Add(1); released <- struct{}{} })
	<-released
	if d := time.Since(start); d > time.Second {
		t.Fatalf("held %v", d)
	}
	close(block)
	h.stop()
	if n.Load() != 1 {
		t.Fatalf("released %d times", n.Load())
	}
}

// Переполнение, остановка и пустой пакет — отпускаем сразу.
func TestHolderReleasesImmediatelyWhenItCannotHold(t *testing.T) {
	block := make(chan struct{})
	h := newHolder(func([]byte) { <-block }, time.Minute, 1)
	var n atomic.Int32
	rel := func() { n.Add(1) }
	h.push([]byte("busy"), func() {}) // разборщик занят этим
	time.Sleep(10 * time.Millisecond)
	h.push([]byte("queued"), func() {})
	h.push([]byte("overflow"), rel)
	h.push(nil, rel)
	if n.Load() != 2 {
		t.Fatalf("overflow/empty released %d of 2", n.Load())
	}
	close(block)
	h.stop()
	h.push([]byte("late"), rel)
	if n.Load() != 3 {
		t.Fatal("packet after stop not released")
	}
}
