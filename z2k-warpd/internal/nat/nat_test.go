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
	if err := Ensure(run, "z2ktun0"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"-w -t filter -C FORWARD -o z2ktun0 -j ACCEPT",
		"-w -t filter -A FORWARD -o z2ktun0 -j ACCEPT",
		"-w -t nat -C POSTROUTING -o z2ktun0 -j MASQUERADE",
		"-w -t nat -A POSTROUTING -o z2ktun0 -j MASQUERADE",
		"-w -t mangle -C FORWARD -o z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
		"-w -t mangle -A FORWARD -o z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
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
	if err := Ensure(run, "z2ktun0"); err != nil {
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
	if err := Remove(run, "z2ktun0"); err != nil {
		t.Fatal(err)
	}
	if dels != 4 || present["nat"] != 0 || present["mangle"] != 0 || present["filter"] != 0 {
		t.Fatalf("dels=%d present=%v", dels, present)
	}
}
