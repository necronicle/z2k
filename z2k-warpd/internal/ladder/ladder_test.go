package ladder

import (
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

func ep(ports ...int) account.Endpoint { return account.Endpoint{V4: "8.6.112.0", Ports: ports} }

func TestOrderIsWgDefaultThenPortsThenH2(t *testing.T) {
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

func TestWrapAppliesCooldown(t *testing.T) {
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
	l := New(ep(), nil)
	t0 := time.Unix(1000, 0)
	l.Next(t0)
	_, wait := l.Next(t0.Add(Cooldown + time.Second))
	if wait != 0 {
		t.Fatalf("wait %v after cooldown elapsed", wait)
	}
}

func TestPortsDeduplicated(t *testing.T) {
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
