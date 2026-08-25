package nat

import (
	"errors"
	"strings"
	"testing"
)

func TestEnsureIsIdempotentViaCheck(t *testing.T) {
	var got []string
	run := func(n string, a ...string) (string, error) {
		got = append(got, strings.Join(a, " "))
		if a[3] == "-C" {
			return "", errors.New("no rule")
		}
		return "", nil
	}
	if err := Ensure(run, "z2ktun0", 1240); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"-w -t filter -C FORWARD -o z2ktun0 -j ACCEPT",
		"-w -t filter -A FORWARD -o z2ktun0 -j ACCEPT",
		"-w -t nat -C POSTROUTING -o z2ktun0 -j MASQUERADE",
		"-w -t nat -A POSTROUTING -o z2ktun0 -j MASQUERADE",
		"-w -t mangle -C FORWARD -o z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
		"-w -t mangle -A FORWARD -o z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
		"-w -t mangle -C FORWARD -i z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240",
		"-w -t mangle -A FORWARD -i z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240",
	}
	if len(got) != len(want) {
		t.Fatalf("%q", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%d: %q != %q", i, got[i], want[i])
		}
	}
}

func TestEnsureSkipsAddWhenPresent(t *testing.T) {
	var adds int
	run := func(n string, a ...string) (string, error) {
		if a[3] == "-A" {
			adds++
		}
		return "", nil
	}
	if err := Ensure(run, "z2ktun0", 1240); err != nil {
		t.Fatal(err)
	}
	if adds != 0 {
		t.Fatalf("added %d rules that already existed", adds)
	}
}

func TestRemoveLoopsUntilGone(t *testing.T) {
	present := map[string]int{"filter": 1, "nat": 2, "mangle": 1} // дубликаты от старых запусков
	var dels int
	run := func(n string, a ...string) (string, error) {
		tbl := a[2]
		switch a[3] {
		case "-C":
			if present[tbl] > 0 {
				return "", nil
			}
			return "", errors.New("no rule")
		case "-D":
			present[tbl]--
			dels++
		}
		return "", nil
	}
	if err := Remove(run, "z2ktun0", 1240); err != nil {
		t.Fatal(err)
	}
	if dels != 4 || present["nat"] != 0 || present["mangle"] != 0 || present["filter"] != 0 {
		t.Fatalf("dels=%d present=%v", dels, present)
	}
}

// MSS ЗАЖИМАЕТСЯ В ОБЕ СТОРОНЫ. Замер на роутере владельца 2026-08-25, живой
// трафик телефона через туннель:
//
//	SYN     клиент -> в туннель   : mss 1240   (140 из 140 — зажат)
//	SYN-ACK сервер -> из туннеля  : mss 1460   (140 из 140 — НЕ зажат)
//
// Клиенту разрешалось слать в туннель с MTU 1280 сегменты по 1460. Скачивание
// шло (156 МБ за прогон), а всё, что клиент ОТПРАВЛЯЕТ крупнее ~1240 байт,
// обрывалось: жалоба из поля звучала как «карты не грузятся, hh падает».
//
// Обратное правило НЕ зеркальное: SYN-ACK уходит через мост с MTU 1500, и
// clamp-mss-to-pmtu дал бы там те же 1460. Нужен явный set-mss по MTU туннеля.
//
// После починки замер повторён: 176 из 176 соединений видят mss 1240.
func TestMSSClampedBothDirections(t *testing.T) {
	var out, in bool
	for _, r := range Rules("z2ktun0", 1240) {
		s := strings.Join(r, " ")
		if !strings.Contains(s, "TCPMSS") {
			continue
		}
		if strings.Contains(s, "-o z2ktun0") && strings.Contains(s, "--clamp-mss-to-pmtu") {
			out = true
		}
		if strings.Contains(s, "-i z2ktun0") && strings.Contains(s, "--set-mss 1240") {
			in = true
		}
	}
	if !out {
		t.Error("нет зажима на пути В туннель")
	}
	if !in {
		t.Error("нет зажима на пути ИЗ туннеля — клиент будет слать 1460 в MTU 1280")
	}
}

// Значение считается от MTU, а не вписано числом: два числа в разных местах
// разъедутся при первой же смене MTU.
func TestMSSFollowsGivenValue(t *testing.T) {
	found := false
	for _, r := range Rules("z2ktun0", 1000) {
		if strings.Contains(strings.Join(r, " "), "--set-mss 1000") {
			found = true
		}
	}
	if !found {
		t.Error("--set-mss не следует переданному значению")
	}
}
