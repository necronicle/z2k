package engine

import (
	"testing"
	"time"
)

// Пакет до 2026-08-08 не имел ни одного теста, хотя держит всю логику
// «пробить домен или нет». Оба дефекта, которые эти тесты сторожат, жили
// здесь месяцами и были найдены чтением, а не прогоном.

// Уронённое из-за переполненного семафора наблюдение НЕ должно сжигать
// cooldown: иначе домен замолкает на весь ProbeCooldown, хотя пробы по нему
// не было вовсе. Раньше запись в cooldown стояла внутри shouldProbe, то есть
// ДО попытки занять слот, и комментарий «домен подхватится на следующем
// запросе» был ложным — следующий запрос упирался в этот же cooldown.
func TestEligibleDoesNotBurnCooldown(t *testing.T) {
	s := newState()
	const d = "example.com"
	const cd = time.Minute

	if !s.eligible(d, cd) {
		t.Fatalf("свежий домен должен быть eligible")
	}
	// Слот не заняли (эмулируем переполненный семафор) — домен обязан
	// остаться доступным для следующего наблюдения.
	if !s.eligible(d, cd) {
		t.Fatalf("после отброшенного наблюдения домен должен остаться eligible")
	}
	if len(s.cooldown) != 0 {
		t.Fatalf("eligible не должен мутировать cooldown, а там %d записей", len(s.cooldown))
	}

	// А вот после markProbed — замолкает.
	s.markProbed(d)
	if s.eligible(d, cd) {
		t.Fatalf("после markProbed домен обязан быть в cooldown")
	}
	if len(s.cooldown) != 1 {
		t.Fatalf("ожидали одну запись в cooldown, получили %d", len(s.cooldown))
	}
}

func TestEligibleRespectsCooldownExpiry(t *testing.T) {
	s := newState()
	const d = "example.com"
	s.markProbed(d)

	if s.eligible(d, time.Hour) {
		t.Fatalf("в пределах окна домен не должен быть eligible")
	}
	// Окно истекло — снова можно.
	s.mu.Lock()
	s.cooldown[d] = time.Now().Add(-2 * time.Hour)
	s.mu.Unlock()
	if !s.eligible(d, time.Hour) {
		t.Fatalf("после истечения окна домен должен снова стать eligible")
	}
}

// skipSet сравнивался на ТОЧНОЕ совпадение, а хостлисты nfqws2 суффиксные:
// оператор пишет googlevideo.com и ожидает, что поддомены тоже исключены.
// Из-за точного сравнения на probe уходил ровно тот трафик, который явно
// просили не трогать, и каждый уникальный поддомен занимал слот в cooldown.
func TestSkipSetMatchesSuffix(t *testing.T) {
	s := newState()
	s.skipSet["googlevideo.com"] = false
	s.skipSet["example.org"] = false

	cases := []struct {
		domain string
		want   bool
	}{
		{"googlevideo.com", true},                   // точное
		{"rr3---sn-4g5e6nez.googlevideo.com", true}, // поддомен
		{"a.b.c.googlevideo.com", true},             // глубокий поддомен
		{"example.org", true},                       // точное
		{"www.example.org", true},                   // поддомен
		{"notgooglevideo.com", false},               // НЕ суффикс по метке
		{"googlevideo.com.evil.tld", false},         // подстрока, но не суффикс
		{"example.com", false},                      // другой домен
		{"org", false},                              // родитель, не потомок
	}
	for _, c := range cases {
		s.mu.Lock()
		got := s.skippedLocked(c.domain)
		s.mu.Unlock()
		if got != c.want {
			t.Errorf("skippedLocked(%q) = %v, ожидали %v", c.domain, got, c.want)
		}
	}
}

func TestEligibleHonoursSkipAndBypass(t *testing.T) {
	s := newState()
	s.skipSet["skipme.com"] = false
	s.bypassed["done.com"] = struct{}{}

	if s.eligible("sub.skipme.com", time.Minute) {
		t.Errorf("поддомен из skip-листа не должен пробиваться")
	}
	if s.eligible("done.com", time.Minute) {
		t.Errorf("уже обойдённый домен не должен пробиваться")
	}
	if !s.eligible("fresh.com", time.Minute) {
		t.Errorf("незнакомый домен должен пробиваться")
	}
}

// Без эвикции map росла на каждый уникальный домен и не отдавала память
// обратно даже после delete — на роутере с 64 МБ это односторонний счёт.
func TestEvictCooldownDropsOnlyExpired(t *testing.T) {
	s := newState()
	const cd = time.Minute

	s.cooldown["fresh.com"] = time.Now()
	s.cooldown["old1.com"] = time.Now().Add(-2 * time.Minute)
	s.cooldown["old2.com"] = time.Now().Add(-10 * time.Minute)

	removed := s.evictCooldown(cd)
	if removed != 2 {
		t.Fatalf("ожидали удаление 2 протухших, удалено %d", removed)
	}
	if _, ok := s.cooldown["fresh.com"]; !ok {
		t.Errorf("свежую запись удалять нельзя")
	}
	if len(s.cooldown) != 1 {
		t.Errorf("в cooldown должна остаться 1 запись, осталось %d", len(s.cooldown))
	}
}

func TestEvictCooldownEmptyIsNoop(t *testing.T) {
	s := newState()
	if n := s.evictCooldown(time.Minute); n != 0 {
		t.Fatalf("на пустой карте ожидали 0, получили %d", n)
	}
}
