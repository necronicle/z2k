package domainroute

import (
	"sync"
	"time"
)

// Ответ DNS придерживаем, пока его адреса не легли в наборы. Иначе устройство
// успевает открыть соединение раньше, чем адрес попал в набор: захват 14.11 —
// SYN через 3 мс после ответа, адрес в наборе позже, и первое соединение к
// исключению уходило в WARP.
//
// holdMax — дольше ответ не держим, даже если запись в наборы не кончилась.
// Самый долгий путь записи — первое устройство в маршрутизации: ipset create и
// add одним restore (~10 мс), iptables -C и -A (~100 мс каждая; замер на
// роутере Марка 14.11) — около 230 мс. Предел вдвое больше и меньше секунды,
// после которой резолверы устройств повторяют запрос.
//
// holdQueueLen — очередь ядра по умолчанию (1024): столько и разборщику.
const (
	holdMax      = 500 * time.Millisecond
	holdQueueLen = 1024
)

type heldPacket struct {
	packet  []byte
	release func()
}

// holder разбирает пакеты по одному, в порядке прихода: обрывки ответа по
// TCP собираются только так. release пакета вызывается ровно один раз — после
// разбора или по holdMax, что раньше.
type holder struct {
	mu       sync.Mutex
	stopping bool
	jobs     chan heldPacket
	done     chan struct{}
	limit    time.Duration
}

func newHolder(handle func([]byte), limit time.Duration, queue int) *holder {
	h := &holder{jobs: make(chan heldPacket, queue), done: make(chan struct{}), limit: limit}
	go func() {
		defer close(h.done)
		for j := range h.jobs {
			handle(j.packet)
			if j.release != nil {
				j.release()
			}
		}
	}()
	return h
}

// push: release == nil — копия пакета (NFLOG), держать нечего.
func (h *holder) push(packet []byte, release func()) {
	if release != nil {
		release = releaseOnce(h.limit, release)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.stopping || len(packet) == 0 {
		if release != nil {
			release()
		}
		return
	}
	select {
	case h.jobs <- heldPacket{packet, release}:
	default:
		// Разборщик не успевает: ответ отпускаем сразу, без обучения.
		if release != nil {
			release()
		}
	}
}

// stop разбирает и отпускает всё принятое; новые пакеты отпускаются сразу.
func (h *holder) stop() {
	h.mu.Lock()
	if !h.stopping {
		h.stopping = true
		close(h.jobs)
	}
	h.mu.Unlock()
	<-h.done
}

func releaseOnce(limit time.Duration, release func()) func() {
	var once sync.Once
	fire := func() { once.Do(release) }
	t := time.AfterFunc(limit, fire)
	return func() {
		t.Stop()
		fire()
	}
}
