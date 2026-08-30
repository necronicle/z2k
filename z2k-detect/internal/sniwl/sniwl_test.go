package sniwl

import (
	"net"
	"strings"
	"testing"
)

func TestParseCandidatesKeepsFileOrder(t *testing.T) {
	// Порядок файла и есть приоритет: победителем считается первое прошедшее
	// имя, поэтому пересортировка здесь была бы не оптимизацией, а сменой
	// вердикта.
	in := `# заголовок
# ещё комментарий

hcaptcha.com
vk.com
2gis.com
`
	got := ParseCandidates(strings.NewReader(in))
	want := []Candidate{
		{Name: "hcaptcha.com", Line: 4},
		{Name: "vk.com", Line: 5},
		{Name: "2gis.com", Line: 6},
	}
	if len(got) != len(want) {
		t.Fatalf("получено %d кандидатов, ждали %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("кандидат %d: %+v, ждали %+v", i, got[i], want[i])
		}
	}
}

func TestParseCandidatesSkipsJunkAndDedups(t *testing.T) {
	in := strings.Join([]string{
		"disk.rzd.ru",
		"   ",
		"DISK.RZD.RU",       // дубль в другом регистре
		"not a hostname",    // пробелы
		"nodot",             // без точки
		"ok.ru # хвостовой", // хвостовой комментарий отрезается
		"..bad..",
		"akashi.vk-portal.net",
	}, "\n")
	got := ParseCandidates(strings.NewReader(in))
	want := []string{"disk.rzd.ru", "ok.ru", "akashi.vk-portal.net"}
	if len(got) != len(want) {
		t.Fatalf("получено %+v, ждали %v", got, want)
	}
	for i := range want {
		if got[i].Name != want[i] {
			t.Errorf("кандидат %d = %q, ждали %q", i, got[i].Name, want[i])
		}
	}
	// Номер строки должен указывать на настоящую строку файла, иначе
	// провенанс отправит человека не туда.
	if got[1].Line != 6 {
		t.Errorf("ok.ru на строке %d, ждали 6", got[1].Line)
	}
}

func TestOrderWithIncumbentPutsItFirst(t *testing.T) {
	cands := []Candidate{
		{Name: "a.ru", Line: 1},
		{Name: "b.ru", Line: 2},
		{Name: "c.ru", Line: 3},
	}
	got := OrderWithIncumbent(cands, "c.ru")
	if got[0].Name != "c.ru" || got[0].Line != 3 {
		t.Fatalf("первым идёт %+v, ждали c.ru:3", got[0])
	}
	if len(got) != 3 {
		t.Fatalf("длина %d, ждали 3 — действующее имя не должно дублироваться", len(got))
	}
	if got[1].Name != "a.ru" || got[2].Name != "b.ru" {
		t.Errorf("остаток переставлен: %+v", got)
	}
}

func TestOrderWithIncumbentUnknownName(t *testing.T) {
	cands := []Candidate{{Name: "a.ru", Line: 1}}
	got := OrderWithIncumbent(cands, "ручное.имя.ru")
	if len(got) != 2 || got[0].Name != "ручное.имя.ru" {
		t.Fatalf("имя не из файла должно идти первым: %+v", got)
	}
}

func TestOrderWithIncumbentEmpty(t *testing.T) {
	cands := []Candidate{{Name: "a.ru", Line: 1}}
	got := OrderWithIncumbent(cands, "")
	if len(got) != 1 || got[0].Name != "a.ru" {
		t.Fatalf("пустое действующее имя не должно менять список: %+v", got)
	}
}

func TestNetKeyMasksTo16(t *testing.T) {
	cases := []struct {
		ip   string
		ok   bool
		cidr string
	}{
		{"5.9.100.200", true, "5.9.0.0/16"},
		{"88.198.0.1", true, "88.198.0.0/16"},
		{"1.2.3.4", true, "1.2.0.0/16"},
		// Непубличные адреса характеризовать нельзя: их /16 попал бы в
		// --ipset профиля и натравил фейковый ClientHello на локалку.
		{"192.168.1.1", false, ""},
		{"10.0.0.1", false, ""},
		{"172.16.240.1", false, ""},
		{"127.0.0.1", false, ""},
		{"169.254.1.1", false, ""},
		{"100.64.0.1", false, ""},
		{"224.0.0.1", false, ""},
		{"0.0.0.0", false, ""},
		{"255.255.255.255", false, ""},
		{"2a00:1450:4010::200e", false, ""},
	}
	for _, c := range cases {
		key, ok := NetKeyString(c.ip)
		if ok != c.ok {
			t.Errorf("%s: ok=%v, ждали %v", c.ip, ok, c.ok)
			continue
		}
		if !ok {
			continue
		}
		if got := CIDR(key); got != c.cidr {
			t.Errorf("%s → %s, ждали %s", c.ip, got, c.cidr)
		}
	}
}

func TestNetKeyIgnoresHostBits(t *testing.T) {
	a, _ := NetKeyString("5.9.0.1")
	b, _ := NetKeyString("5.9.255.254")
	if a != b {
		t.Fatalf("адреса одной /16 дали разные ключи: %08x против %08x", a, b)
	}
	c, _ := NetKeyString("5.10.0.1")
	if a == c {
		t.Fatal("соседние /16 склеились в один ключ")
	}
}

func TestNetKeyRejectsGarbage(t *testing.T) {
	if _, ok := NetKeyString("не адрес"); ok {
		t.Error("мусор принят за адрес")
	}
	if _, ok := NetKey(nil); ok {
		t.Error("nil принят за адрес")
	}
	if _, ok := NetKey(net.IP{1, 2}); ok {
		t.Error("огрызок принят за адрес")
	}
}

func TestParseCIDR16(t *testing.T) {
	cases := []struct {
		in   string
		ok   bool
		want string
	}{
		{"5.9.0.0/16", true, "5.9.0.0/16"},
		// Оператор мог вписать /24 или голый адрес — сеть та же.
		{"5.9.128.0/24", true, "5.9.0.0/16"},
		{"5.9.100.200", true, "5.9.0.0/16"},
		{"", false, ""},
		{"мусор", false, ""},
		{"192.168.0.0/16", false, ""},
	}
	for _, c := range cases {
		key, ok := ParseCIDR16(c.in)
		if ok != c.ok {
			t.Errorf("%q: ok=%v, ждали %v", c.in, ok, c.ok)
			continue
		}
		if ok && CIDR(key) != c.want {
			t.Errorf("%q → %s, ждали %s", c.in, CIDR(key), c.want)
		}
	}
}

func TestFirstRoutableSkipsPrivate(t *testing.T) {
	ip, key, ok := FirstRoutable([]string{"192.168.1.5", "2a00::1", "5.9.100.200", "8.8.8.8"})
	if !ok {
		t.Fatal("публичный адрес в списке есть, а не нашли")
	}
	if ip != "5.9.100.200" || CIDR(key) != "5.9.0.0/16" {
		t.Fatalf("выбран %s (%s), ждали 5.9.100.200 (5.9.0.0/16)", ip, CIDR(key))
	}
	if _, _, ok := FirstRoutable([]string{"192.168.1.5"}); ok {
		t.Error("только приватные адреса — характеризовать нечего")
	}
	if _, _, ok := FirstRoutable(nil); ok {
		t.Error("пустой список принят")
	}
}

func TestStatusValid(t *testing.T) {
	// Только OK и DETECTED — измерения коробки; остальное про линию и сервер,
	// и путать их нельзя, иначе перебор пойдёт по мёртвому адресу.
	for _, s := range []Status{StatusOK, StatusDetected} {
		if !s.Valid() {
			t.Errorf("%s должен считаться измерением", s)
		}
	}
	for _, s := range []Status{StatusBreak, StatusFail, Status("")} {
		if s.Valid() {
			t.Errorf("%s не измерение коробки", s)
		}
	}
}
