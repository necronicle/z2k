package ladder

import (
	"strings"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

// noFallback — проверить лестницу БЕЗ запасных адресов.
//
// Тесты ниже описывают порядок выданных ступеней и место h2; хвост из запасных
// эндпоинтов к их предмету не относится и только мешал бы сравнению дословно.
// Сами запасные проверяются отдельно: TestFallbackHostsAfterRegistered.
func noFallback(t *testing.T) {
	t.Helper()
	saved := fallbackHosts
	fallbackHosts = nil
	t.Cleanup(func() { fallbackHosts = saved })
}

func ep(ports ...int) account.Endpoint { return account.Endpoint{V4: "8.6.112.0", Ports: ports} }

func TestOrderIsWgDefaultThenPortsThenH2(t *testing.T) {
	noFallback(t)
	l := New(ep(854, 859), nil)
	H := "8.6.112.0"
	want := []account.Step{{Transport: "wg", Host: H, Port: 2408}, {Transport: "wg", Host: H, Port: 854}, {Transport: "wg", Host: H, Port: 859}, {Transport: "h2", Port: 443}}
	for i, w := range want {
		if l.Current() != w {
			t.Fatalf("step %d: %+v", i, l.Current())
		}
		if i < len(want)-1 {
			l.Next(time.Unix(0, 0))
		}
	}
	if !l.OnH2() {
		t.Fatal("last step must be h2")
	}
}

func TestStartsFromLastGood(t *testing.T) {
	l := New(ep(854), &account.Step{Transport: "wg", Host: "8.6.112.0", Port: 854})
	if l.Current() != (account.Step{Transport: "wg", Host: "8.6.112.0", Port: 854}) {
		t.Fatalf("%+v", l.Current())
	}
	if l.Index() != 1 {
		t.Fatalf("index %d", l.Index())
	}
}

func TestUnknownLastGoodIgnored(t *testing.T) {
	l := New(ep(854), &account.Step{Transport: "wg", Host: "8.6.112.0", Port: 9999})
	if l.Current() != (account.Step{Transport: "wg", Host: "8.6.112.0", Port: 2408}) {
		t.Fatalf("%+v", l.Current())
	}
}

func TestStartAtLastStepStillTriesTheRestBeforeCooldown(t *testing.T) {
	noFallback(t)
	// Поле r-79.4: last_good=h2 (последняя ступень) → первый же Next
	// сматывался в начало и объявлял «полный проход провален», уходя на
	// 5 минут. WG-ступени не пробовались НИ РАЗУ.
	e := account.Endpoint{V4: "8.6.112.0", Ports: []int{500, 1701, 4500}}
	l := New(e, &account.Step{Transport: "h2", Port: 443})
	if !l.OnH2() {
		t.Fatalf("start: %+v", l.Current())
	}
	t0 := time.Unix(1000, 0)
	seen := map[string]bool{Label(l.Current()): true}
	for i := 0; i < 4; i++ { // ещё 4 ступени: 2408, 500, 1701, 4500
		s, wait := l.Next(t0)
		if wait != 0 {
			t.Fatalf("шаг %d: кулдаун до того, как перебрали все ступени (%v)", i, wait)
		}
		seen[Label(s)] = true
	}
	if len(seen) != 5 {
		t.Fatalf("перебрали не все ступени: %v", seen)
	}
	if _, wait := l.Next(t0); wait == 0 {
		t.Fatal("после полного круга кулдаун обязан быть")
	}
}

func TestWrapAppliesCooldown(t *testing.T) {
	noFallback(t)
	l := New(ep(), nil) // wg:2408, h2:443
	t0 := time.Unix(1000, 0)
	s, wait := l.Next(t0) // -> h2
	if s != (account.Step{Transport: "h2", Port: 443}) || wait != 0 {
		t.Fatalf("%+v %v", s, wait)
	}
	s, wait = l.Next(t0.Add(time.Second)) // wrap
	if s != (account.Step{Transport: "wg", Host: "8.6.112.0", Port: 2408}) {
		t.Fatalf("%+v", s)
	}
	if wait < 4*time.Minute || wait > Cooldown {
		t.Fatalf("no cooldown: %v", wait)
	}
	_, wait = l.Next(t0.Add(time.Second)) // внутри прохода — без ожидания
	if wait != 0 {
		t.Fatalf("unexpected wait %v", wait)
	}
}

func TestWrapAfterCooldownHasNoWait(t *testing.T) {
	noFallback(t)
	l := New(ep(), nil)
	t0 := time.Unix(1000, 0)
	l.Next(t0)
	_, wait := l.Next(t0.Add(Cooldown + time.Second))
	if wait != 0 {
		t.Fatalf("wait %v after cooldown elapsed", wait)
	}
}

func TestPortsDeduplicated(t *testing.T) {
	noFallback(t)
	l := New(ep(2408, 854, 854, 0, -1, 70000), nil)
	n := 1
	for !l.OnH2() {
		l.Next(time.Unix(0, 0))
		n++
	}
	if n != 3 {
		t.Fatalf("want 3 steps (2408, 854, h2), got %d", n)
	}
}

func TestGoodReturnsCurrent(t *testing.T) {
	l := New(ep(854), nil)
	l.Next(time.Unix(0, 0))
	if g := l.Good(); g != (account.Step{Transport: "wg", Host: "8.6.112.0", Port: 854}) {
		t.Fatalf("%+v", g)
	}
}

func TestString(t *testing.T) {
	if s := (account.Step{Transport: "wg", Host: "8.6.112.0", Port: 2408}); Label(s) != "wg:8.6.112.0:2408" {
		t.Fatal(Label(s))
	}
	if s := (account.Step{Transport: "h2", Port: 443}); Label(s) != "h2:443" {
		t.Fatal(Label(s))
	}
}

func TestH2ComesAfterFirstFiveWGSteps(t *testing.T) {
	l := New(account.Endpoint{V4: "8.6.112.0", Ports: []int{1, 2, 3, 4, 5, 6, 7, 8}}, nil)
	got := ""
	for i := 0; ; i++ {
		if got != "" {
			got += " "
		}
		got += Label(l.Current())
		if i == 9 {
			break
		}
		l.Next(time.Unix(0, 0))
	}
	want := "wg:8.6.112.0:2408 wg:8.6.112.0:1 wg:8.6.112.0:2 wg:8.6.112.0:3 wg:8.6.112.0:4 h2:443 wg:8.6.112.0:5 wg:8.6.112.0:6 wg:8.6.112.0:7 wg:8.6.112.0:8"
	if got != want {
		t.Fatalf("\n got %s\nwant %s", got, want)
	}
}

func TestAltHostsAfterPrimary(t *testing.T) {
	noFallback(t)
	e := account.Endpoint{V4: "8.6.112.0", Ports: []int{854},
		Alt: []account.HostPorts{{Host: "162.159.192.10", Ports: []int{500}}, {Host: "8.6.112.0", Ports: []int{1}}}}
	l := New(e, nil)
	got := ""
	for {
		if got != "" {
			got += " "
		}
		got += Label(l.Current())
		if l.OnH2() {
			break
		}
		l.Next(time.Unix(0, 0))
	}
	want := "wg:8.6.112.0:2408 wg:8.6.112.0:854 wg:162.159.192.10:2408 wg:162.159.192.10:500 h2:443"
	if got != want {
		t.Fatalf("\n got %s\nwant %s", got, want)
	}
}

func TestFixedAlwaysSameStepWithCooldown(t *testing.T) {
	l := NewFixed(account.Step{Transport: "h2", Port: 443})
	t0 := time.Unix(1000, 0)
	s, wait := l.Next(t0)
	if s != (account.Step{Transport: "h2", Port: 443}) || wait < 4*time.Minute {
		t.Fatalf("%+v %v", s, wait)
	}
	if !l.OnH2() {
		t.Fatal("single h2 step must report OnH2")
	}
}

// РЕГРЕСС p-79.13: h2 сняли из автоматической лестницы — и у тех, чей WG не
// работает В ПРИНЦИПЕ, WARP отключился целиком.
//
// Так бывает, когда Cloudflare выдал первичный эндпоинт из блокируемого
// диапазона, а запасных хостов в регистрации нет: все WG-ступени ведут на
// один мёртвый адрес, и h2 — единственный оставшийся транспорт. В поле это
// выглядело как «28 раз no handshake подряд» и туннель, не несущий трафик.
//
// Снятие обосновывалось тем, что h2 работает ловушкой: поднимается, объявляет
// готовность и не возит ничего. Ловушка закрыта монитором живости — проба
// идёт В ИНТЕРФЕЙС через SO_BINDTODEVICE и требует warp=on, два провала
// подряд означают Dead (health.TestTwoProbeFailuresAreDead). Замер, на
// котором строилось снятие, сделан на ОДНОЙ линии; переносить его на весь
// флот было ошибкой.
func TestH2StaysInAutomaticLadder(t *testing.T) {
	// Худший случай из поля: один хост, ни одного запасного.
	l := New(account.Endpoint{V4: "162.159.192.6", Ports: []int{500, 1701, 4500}}, nil)
	var h2 bool
	for i := 0; i < l.Len(); i++ {
		if l.steps[i].Transport == "h2" {
			h2 = true
		}
	}
	if !h2 {
		t.Fatal("h2 обязан быть в лестнице: без него у мёртвого WG-диапазона транспорта не остаётся вовсе")
	}
}

// ЗАПАСНЫЕ ЭНДПОИНТЫ, КОГДА ВЫДАННЫЕ МЕРТВЫ.
//
// Поле 2026-08-25: Cloudflare выдал устройству ТОЛЬКО 162.159.192.4 — диапазон,
// который режут целиком. Перерегистрация не спасла: со второй попытки пришёл
// другой адрес из того же блока, то есть «новая регистрация плохого диапазона
// не содержит» оказалось неверным допущением. WARP не поднимался вовсе.
//
// Замер на роутере владельца показал, что ключ к выданному адресу НЕ привязан:
//
//	8.6.112.1      handshake ok   (устройству не выдавался)
//	8.47.69.1      handshake ok   (другой диапазон)
//	188.114.96.1   handshake ok
//	188.114.97.1   handshake ok
//	162.159.195.1  no handshake
//	162.159.192.10 no handshake   (СВОЙ запасной — диапазон режут)
//
// Значит когда выданные адреса мертвы, можно идти на известные рабочие.
func TestFallbackHostsAfterRegistered(t *testing.T) {
	// Худший случай из поля: один хост, весь в блокируемом диапазоне.
	l := New(account.Endpoint{V4: "162.159.192.4", Ports: []int{500, 1701, 4500}}, nil)
	var haveFallback, haveRegistered bool
	firstFallback := -1
	lastRegistered := -1
	for i := 0; i < l.Len(); i++ {
		s := l.steps[i]
		if s.Transport != "wg" {
			continue
		}
		if s.Host == "162.159.192.4" {
			haveRegistered = true
			lastRegistered = i
			continue
		}
		haveFallback = true
		if firstFallback < 0 {
			firstFallback = i
		}
	}
	if !haveRegistered {
		t.Fatal("выданный адрес пропал из лестницы")
	}
	if !haveFallback {
		t.Fatal("запасных адресов нет — при мёртвом диапазоне лестница пуста")
	}
	if firstFallback < lastRegistered {
		t.Fatalf("запасные идут ДО выданных (%d < %d): выданный адрес обязан пробоваться первым",
			firstFallback, lastRegistered)
	}
}

// Запасной адрес, уже выданный устройству, дублировать не нужно.
func TestFallbackNotDuplicated(t *testing.T) {
	l := New(account.Endpoint{V4: "8.6.112.1", Ports: []int{}}, nil)
	n := 0
	for i := 0; i < l.Len(); i++ {
		if l.steps[i].Transport == "wg" && l.steps[i].Host == "8.6.112.1" && l.steps[i].Port == 2408 {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("адрес 8.6.112.1:2408 встречается %d раз", n)
	}
}

// СПИСОК ЗАПАСНЫХ — ДАННЫЕ, А НЕ КОД.
//
// Зашитый в бинарник список стареет: 162.159.193.x работал, а к концу 2024
// перестал — и остался бы в коде навсегда, пока кто-нибудь не выпустит релиз с
// пересборкой под пять арок. Адреса обязаны обновляться как список, а не как
// программа.
//
// Встроенный список остаётся запасным для случая, когда файла нет: свежая
// установка не должна оказаться вообще без запасных адресов.
func TestFallbackHostsAreReplaceable(t *testing.T) {
	saved := fallbackHosts
	t.Cleanup(func() { fallbackHosts = saved })

	SetFallbackHosts([]string{"203.0.113.7"})
	l := New(account.Endpoint{V4: "162.159.192.4"}, nil)
	found := false
	for i := 0; i < l.Len(); i++ {
		if l.steps[i].Host == "203.0.113.7" {
			found = true
		}
		if l.steps[i].Host == "8.6.112.1" {
			t.Fatal("встроенный список не заменился, а дополнился")
		}
	}
	if !found {
		t.Fatal("заданный список не применился")
	}

	// Пустой список не должен оставлять роутер без запасных: возвращаем
	// встроенный.
	SetFallbackHosts(nil)
	l = New(account.Endpoint{V4: "162.159.192.4"}, nil)
	builtin := false
	for i := 0; i < l.Len(); i++ {
		if l.steps[i].Host == "8.6.112.1" {
			builtin = true
		}
	}
	if !builtin {
		t.Fatal("пустой список оставил лестницу без запасных адресов")
	}
}

// ДИАПАЗОНЫ, А НЕ АДРЕСА.
//
// Четыре адреса, измеренные на одной линии, — догадка: у другого провайдера их
// может резать, и человек вернётся с той же жалобой. Блокируют СЕТЯМИ, поэтому
// хранить надо сети, а адреса из них роутер подбирает сам — тем же перебором,
// которым и так проверяет каждую ступень.
func TestCIDRExpandsToSeveralHosts(t *testing.T) {
	saved := fallbackHosts
	t.Cleanup(func() { fallbackHosts = saved })

	SetFallbackHosts([]string{"203.0.113.0/24"})
	l := New(account.Endpoint{V4: "162.159.192.4"}, nil)
	seen := map[string]bool{}
	for i := 0; i < l.Len(); i++ {
		h := l.steps[i].Host
		if strings.HasPrefix(h, "203.0.113.") {
			seen[h] = true
		}
	}
	if len(seen) < 2 {
		t.Fatalf("из сети взят %d адрес — одна проба не отличает мёртвую сеть от мёртвого адреса", len(seen))
	}
	for h := range seen {
		if h == "203.0.113.0" {
			t.Fatal("взят адрес сети")
		}
	}
}
