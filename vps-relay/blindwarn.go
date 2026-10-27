package main

import (
	"log"
	"sync"
	"time"
)

// blindWarn жалуется, что настоящий адрес клиента до нас не доходит
// (прокси перестал передавать его — полевой случай 05.08.2026, 1120 из 1120
// соединений как 127.0.0.1), но не чаще раза в минуту: иначе на потоке в
// тысячу туннелей журнал захлебнётся. Одна реализация на обе жалобы —
// ограничитель регистраций и кэш повторов AUTH.
type blindWarn struct {
	mu   sync.Mutex
	last time.Time
	n    int64
	msg  string // формат с одним %d — сколько случаев набралось с прошлой жалобы
}

// tick учитывает случай и говорит, пора ли кричать; n — накопленное число.
func (w *blindWarn) tick(now time.Time) (n int64, shout bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.n++
	n = w.n
	shout = now.Sub(w.last) >= time.Minute
	if shout {
		w.last = now
		w.n = 0
	}
	return n, shout
}

func (w *blindWarn) warn() {
	if n, shout := w.tick(time.Now()); shout {
		log.Printf(w.msg, n)
	}
}
