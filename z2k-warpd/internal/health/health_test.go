package health

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
)

func mon(probeErr error, calls *int) *Monitor {
	return &Monitor{
		Probe: func(context.Context, string) error { *calls++; return probeErr },
		Doubt: 30 * time.Second,
		Fails: 2,
	}
}

func conn(rx, tx uint64) transport.Health {
	return transport.Health{Connected: true, LastHandshake: time.Unix(1, 0), Rx: rx, Tx: tx}
}

func TestRxGrowingIsAliveWithoutProbe(t *testing.T) {
	var calls int
	m := mon(nil, &calls)
	m.proven = true // свойство про уже доказанный туннель, см. Monitor.Proven
	t0 := time.Unix(1000, 0)
	if v := m.Assess(context.Background(), conn(100, 100), t0, "172.16.0.2"); v != Alive {
		t.Fatal(v)
	}
	if v := m.Assess(context.Background(), conn(200, 300), t0.Add(time.Second), "172.16.0.2"); v != Alive {
		t.Fatal(v)
	}
	if calls != 0 {
		t.Fatalf("probe called %d times", calls)
	}
}

func TestIdleIsAlive(t *testing.T) {
	var calls int
	m := mon(nil, &calls)
	m.proven = true // свойство про уже доказанный туннель, см. Monitor.Proven
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	// ни tx, ни rx не растут 5 минут — никто не пользуется, это не смерть
	if v := m.Assess(context.Background(), conn(100, 100), t0.Add(5*time.Minute), ""); v != Alive {
		t.Fatal(v)
	}
	if calls != 0 {
		t.Fatal("probe on idle")
	}
}

func TestTxWithoutRxTriggersProbeThenAlive(t *testing.T) {
	var calls int
	m := mon(nil, &calls)
	m.proven = true // свойство про уже доказанный туннель, см. Monitor.Proven
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	if v := m.Assess(context.Background(), conn(100, 500), t0.Add(10*time.Second), ""); v != Alive || calls != 0 {
		t.Fatalf("too early: %v calls=%d", v, calls)
	}
	if v := m.Assess(context.Background(), conn(100, 900), t0.Add(31*time.Second), ""); v != Alive || calls != 1 {
		t.Fatalf("probe must run once and pass: %v calls=%d", v, calls)
	}
}

func TestTwoProbeFailuresAreDead(t *testing.T) {
	var calls int
	m := mon(errors.New("timeout"), &calls)
	m.proven = true // свойство про уже доказанный туннель, см. Monitor.Proven
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	if v := m.Assess(context.Background(), conn(100, 500), t0.Add(31*time.Second), ""); v != Doubtful || calls != 1 {
		t.Fatalf("first fail: %v calls=%d", v, calls)
	}
	if v := m.Assess(context.Background(), conn(100, 900), t0.Add(62*time.Second), ""); v != Dead || calls != 2 {
		t.Fatalf("second fail: %v calls=%d", v, calls)
	}
}

func TestProbeRateLimited(t *testing.T) {
	var calls int
	m := mon(errors.New("x"), &calls)
	m.proven = true // свойство про уже доказанный туннель, см. Monitor.Proven
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	m.Assess(context.Background(), conn(100, 500), t0.Add(31*time.Second), "")
	m.Assess(context.Background(), conn(100, 600), t0.Add(32*time.Second), "") // сразу за первой — не пробовать
	if calls != 1 {
		t.Fatalf("probe hammered: %d", calls)
	}
}

func TestDisconnectedIsDoubtfulImmediately(t *testing.T) {
	var calls int
	m := mon(errors.New("x"), &calls)
	m.proven = true // свойство про уже доказанный туннель, см. Monitor.Proven
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	h := transport.Health{Connected: false}
	if v := m.Assess(context.Background(), h, t0.Add(time.Second), ""); v != Doubtful {
		t.Fatal(v)
	}
	if v := m.Assess(context.Background(), h, t0.Add(40*time.Second), ""); v != Dead {
		t.Fatal(v)
	}
}

func TestTransportErrorIsDead(t *testing.T) {
	m := mon(nil, new(int))
	h := transport.Health{Connected: false, Err: errors.New("closed")}
	if v := m.Assess(context.Background(), h, time.Unix(1, 0), ""); v != Dead {
		t.Fatal(v)
	}
}

func TestResetAfterReopen(t *testing.T) {
	var calls int
	m := mon(errors.New("x"), &calls)
	m.proven = true
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	m.Assess(context.Background(), conn(100, 500), t0.Add(31*time.Second), "")
	m.Reset()
	// Счётчик провалов обнулён — но и ДОКАЗАННОСТЬ тоже: за переоткрытием
	// стоит другой транспорт, и то, что возил предыдущий, о нём не говорит
	// ничего. Иначе мёртвая ступень унаследовала бы готовность живой.
	if m.Proven() {
		t.Fatal("Reset обязан снимать доказанность")
	}
	if v := m.Assess(context.Background(), conn(0, 0), t0.Add(32*time.Second), ""); v == Alive {
		t.Fatalf("недоказанный транспорт после Reset не может быть Alive: %v", v)
	}
}

// ГОТОВНОСТЬ — ДОКАЗАННАЯ, А НЕ ОБЪЯВЛЕННАЯ.
//
// Регресс, из-за которого правку MASQUE носило туда-сюда: shell-контракт
// говорит «0 — ready (туннель доказанно несёт трафик)», а монитор объявлял
// Alive на первом же опросе, до единой пробы. Маршруты поднимались на
// непроверенном туннеле, и там, где транспорт не возит, трафик уходил в
// чёрную дыру. Чинить это снятием транспорта из лестницы нельзя: на одной
// линии он мёртв, на другой — единственный рабочий. Решать обязан замер на
// КАЖДОМ роутере, а не выбор, зашитый в код.
func TestNotProvenUntilProbeSucceeds(t *testing.T) {
	m := &Monitor{Doubt: 30 * time.Second, Fails: 2,
		Probe: func(context.Context, string) error { return errors.New("чёрная дыра") }}
	h := transport.Health{Connected: true, Rx: 0, Tx: 100}
	if v := m.Assess(context.Background(), h, time.Unix(1000, 0), "z2ktun0"); v == Alive {
		t.Fatal("недоказанный туннель не может быть Alive")
	}
	if m.Proven() {
		t.Fatal("Proven до успешной пробы")
	}
}

func TestProvenAfterFirstSuccessfulProbe(t *testing.T) {
	m := &Monitor{Doubt: 30 * time.Second, Fails: 2,
		Probe: func(context.Context, string) error { return nil }}
	h := transport.Health{Connected: true, Rx: 0, Tx: 100}
	if v := m.Assess(context.Background(), h, time.Unix(1000, 0), "z2ktun0"); v != Alive {
		t.Fatalf("проба прошла — ждали Alive, получили %v", v)
	}
	if !m.Proven() {
		t.Fatal("Proven не выставлен после успешной пробы")
	}
}

// Доказанный туннель НЕ должен терять готовность от одного сомнения: иначе
// маршрут снимался бы при каждой паузе в трафике.
func TestProvenSurvivesSingleDoubt(t *testing.T) {
	fail := false
	m := &Monitor{Doubt: time.Second, Fails: 2,
		Probe: func(context.Context, string) error {
			if fail {
				return errors.New("нет")
			}
			return nil
		}}
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), transport.Health{Connected: true, Tx: 1}, t0, "z2ktun0")
	fail = true
	v := m.Assess(context.Background(), transport.Health{Connected: true, Tx: 2}, t0.Add(2*time.Second), "z2ktun0")
	if v == Dead {
		t.Fatal("одна неудачная проба не должна убивать доказанный туннель")
	}
	if !m.Proven() {
		t.Fatal("Proven снялся от одного сомнения")
	}
}

// Недоказанный транспорт обязан сдаваться БЫСТРО: пока он не признан мёртвым,
// лестница стоит на нём, а человек — без WARP. Полминуты ожидания на каждой
// ступени превращают перебор в вечность.
func TestUnprovenGivesUpFast(t *testing.T) {
	m := &Monitor{Doubt: 30 * time.Second, Fails: 2,
		Probe: func(context.Context, string) error { return errors.New("чёрная дыра") }}
	h := transport.Health{Connected: true, Tx: 100}
	t0 := time.Unix(1000, 0)
	var dead bool
	for i := 0; i < 20 && !dead; i++ {
		if m.Assess(context.Background(), h, t0.Add(time.Duration(i)*time.Second), "z2ktun0") == Dead {
			dead = true
			if i > 10 {
				t.Fatalf("сдался только через %d с — слишком долго", i)
			}
		}
	}
	if !dead {
		t.Fatal("недоказанный транспорт с падающей пробой обязан стать Dead")
	}
}

// Причина смерти обязана быть ЧИТАЕМОЙ: transport.Health.Err на пути через
// пробу всегда nil, и без Err() в логе стояло «dead (<nil>)».
func TestErrCarriesProbeFailure(t *testing.T) {
	boom := errors.New("probe: warp=off")
	m := &Monitor{Probe: func(context.Context, string) error { return boom }, Doubt: 30 * time.Second, Fails: 2,
		ProveEvery: time.Second}
	now := time.Unix(1000, 0)
	h := transport.Health{Connected: true, LastHandshake: now}
	if v := m.Assess(context.Background(), h, now, "z2ktun0"); v != Doubtful {
		t.Fatalf("первый провал = %v", v)
	}
	if !errors.Is(m.Err(), boom) {
		t.Fatalf("Err() = %v", m.Err())
	}
	now = now.Add(2 * time.Second)
	if v := m.Assess(context.Background(), h, now, "z2ktun0"); v != Dead {
		t.Fatalf("второй провал = %v", v)
	}
	if !errors.Is(m.Err(), boom) {
		t.Fatalf("Err() после смерти = %v", m.Err())
	}
	// Удачная проба причину снимает — иначе старая ошибка переживает выздоровление.
	m.Probe = func(context.Context, string) error { return nil }
	now = now.Add(2 * time.Second)
	if v := m.Assess(context.Background(), h, now, "z2ktun0"); v != Alive {
		t.Fatalf("после удачной пробы = %v", v)
	}
	if m.Err() != nil {
		t.Fatalf("Err() после успеха = %v", m.Err())
	}
}
