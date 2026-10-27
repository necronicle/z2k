package main

import (
	"testing"
	"time"
)

// Жалоба на слепой адрес: первая — сразу, дальше не чаще раза в минуту,
// и каждая называет, сколько случаев накопилось с прошлой.
func TestBlindWarnOncePerMinuteWithCount(t *testing.T) {
	w := &blindWarn{msg: "test %d"}
	t0 := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)

	if n, shout := w.tick(t0); !shout || n != 1 {
		t.Fatalf("первый случай: n=%d shout=%v, ожидалось 1/true", n, shout)
	}
	for i := 0; i < 5; i++ {
		if n, shout := w.tick(t0.Add(30 * time.Second)); shout {
			t.Fatalf("внутри минуты закричал: n=%d", n)
		}
	}
	// Ровно минута — уже пора: граница включительная.
	if n, shout := w.tick(t0.Add(60 * time.Second)); !shout || n != 6 {
		t.Fatalf("ровно через минуту: n=%d shout=%v, ожидалось 6/true", n, shout)
	}
	if n, shout := w.tick(t0.Add(61 * time.Second)); shout || n != 1 {
		t.Fatalf("после крика счётчик не сброшен: n=%d shout=%v", n, shout)
	}
}
