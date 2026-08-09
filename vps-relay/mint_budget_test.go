package main

import (
	"testing"
	"time"
)

// Ограничитель частоты /register считает по адресу — против ботнета это ничто.
// Глобальный счётчик чеканки ловит распределённый флуд, но НЕ отсекает: молча
// отказать в регистрации значит обрезать настоящий наплыв после релиза.
func TestMintAlarmFiresOncePerWindow(t *testing.T) {
	old := *mintAlarmPer
	*mintAlarmPer = 3
	t.Cleanup(func() {
		*mintAlarmPer = old
		mintMu.Lock()
		mintWindow, mintCount, mintAlarmed = time.Time{}, 0, false
		mintMu.Unlock()
	})

	mintMu.Lock()
	mintWindow, mintCount, mintAlarmed = time.Time{}, 0, false
	mintMu.Unlock()

	base := time.Unix(1_700_000_000, 0)
	for i, want := range []bool{false, false, true, false, false} {
		_, got := noteMint(base.Add(time.Duration(i) * time.Second))
		if got != want {
			t.Errorf("чеканка %d: тревога=%v, ожидали %v", i+1, got, want)
		}
	}
}

// Новое окно обнуляет и счётчик, и признак уже поднятой тревоги.
func TestMintWindowResets(t *testing.T) {
	old := *mintAlarmPer
	*mintAlarmPer = 2
	t.Cleanup(func() {
		*mintAlarmPer = old
		mintMu.Lock()
		mintWindow, mintCount, mintAlarmed = time.Time{}, 0, false
		mintMu.Unlock()
	})

	mintMu.Lock()
	mintWindow, mintCount, mintAlarmed = time.Time{}, 0, false
	mintMu.Unlock()

	base := time.Unix(1_700_000_000, 0)
	noteMint(base)
	if _, alarm := noteMint(base); !alarm {
		t.Fatal("тревога должна была подняться на втором")
	}
	// Через час — чистое окно.
	if n, alarm := noteMint(base.Add(time.Hour + time.Second)); n != 1 || alarm {
		t.Fatalf("новое окно: счёт=%d тревога=%v, ожидали 1 и false", n, alarm)
	}
}

// Ноль выключает тревогу совсем — путь отката должен существовать.
func TestMintAlarmDisabledByZero(t *testing.T) {
	old := *mintAlarmPer
	*mintAlarmPer = 0
	t.Cleanup(func() {
		*mintAlarmPer = old
		mintMu.Lock()
		mintWindow, mintCount, mintAlarmed = time.Time{}, 0, false
		mintMu.Unlock()
	})

	mintMu.Lock()
	mintWindow, mintCount, mintAlarmed = time.Time{}, 0, false
	mintMu.Unlock()

	base := time.Unix(1_700_000_000, 0)
	for i := 0; i < 1000; i++ {
		if _, alarm := noteMint(base); alarm {
			t.Fatalf("при нуле тревоги быть не должно (итерация %d)", i)
		}
	}
}
