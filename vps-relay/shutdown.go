package main

import "sync"

// liveSessionsMap — все живые сессии: для триммера бюджета и остановки.
var liveSessionsMap sync.Map

func registerLiveSession(s *session)   { liveSessionsMap.Store(s.id, s) }
func unregisterLiveSession(s *session) { liveSessionsMap.Delete(s.id) }

func forEachSession(fn func(*session)) {
	liveSessionsMap.Range(func(_, v any) bool { fn(v.(*session)); return true })
}
