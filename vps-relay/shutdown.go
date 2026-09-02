package main

import (
	"math/rand/v2"
	"sync"
	"time"
)

// liveSessionsMap — все живые сессии: для триммера бюджета и остановки.
var liveSessionsMap sync.Map

func registerLiveSession(s *session)   { liveSessionsMap.Store(s.id, s) }
func unregisterLiveSession(s *session) { liveSessionsMap.Delete(s.id) }

func forEachSession(fn func(*session)) {
	liveSessionsMap.Range(func(_, v any) bool { fn(v.(*session)); return true })
}

// drainSessions — плавная остановка (спека §3.6, часть про SIGTERM): v2
// получают RETRY_AFTER с разбросом 0–60 с, затем ждём до timeout, остаток
// закрываем с причиной SHUTDOWN.
func drainSessions(timeout time.Duration) {
	n := 0
	forEachSession(func(s *session) {
		n++
		if f := s.proto().info(infoRetryAfter, uint32(rand.IntN(61)), "деплой"); f != nil {
			s.writer.control(f)
		}
	})
	emitEvent(Event{Ev: "shutdown", Streams: n, Detail: "drain"})
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		alive := 0
		forEachSession(func(*session) { alive++ })
		if alive == 0 {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	forEachSession(func(s *session) {
		s.goodbye(rShutdown, "релей останавливается")
		s.killWith("shutdown")
	})
}
