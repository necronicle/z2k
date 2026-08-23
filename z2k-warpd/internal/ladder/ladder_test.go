package ladder

import (
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

func TestOrderIsWgDefaultThenPortsThenH2(t *testing.T) {
	l := New([]int{854, 859}, nil)
	want := []account.Step{{"wg", 2408}, {"wg", 854}, {"wg", 859}, {"h2", 443}}
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
	l := New([]int{854}, &account.Step{Transport: "wg", Port: 854})
	if l.Current() != (account.Step{Transport: "wg", Port: 854}) {
		t.Fatalf("%+v", l.Current())
	}
	if l.Index() != 1 {
		t.Fatalf("index %d", l.Index())
	}
}

func TestUnknownLastGoodIgnored(t *testing.T) {
	l := New([]int{854}, &account.Step{Transport: "wg", Port: 9999})
	if l.Current() != (account.Step{Transport: "wg", Port: 2408}) {
		t.Fatalf("%+v", l.Current())
	}
}

func TestWrapAppliesCooldown(t *testing.T) {
	l := New(nil, nil) // wg:2408, h2:443
	t0 := time.Unix(1000, 0)
	s, wait := l.Next(t0) // -> h2
	if s != (account.Step{Transport: "h2", Port: 443}) || wait != 0 {
		t.Fatalf("%+v %v", s, wait)
	}
	s, wait = l.Next(t0.Add(time.Second)) // wrap
	if s != (account.Step{Transport: "wg", Port: 2408}) {
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
	l := New(nil, nil)
	t0 := time.Unix(1000, 0)
	l.Next(t0)
	_, wait := l.Next(t0.Add(Cooldown + time.Second))
	if wait != 0 {
		t.Fatalf("wait %v after cooldown elapsed", wait)
	}
}

func TestPortsDeduplicated(t *testing.T) {
	l := New([]int{2408, 854, 854, 0, -1, 70000}, nil)
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
	l := New([]int{854}, nil)
	l.Next(time.Unix(0, 0))
	if g := l.Good(); g != (account.Step{Transport: "wg", Port: 854}) {
		t.Fatalf("%+v", g)
	}
}

func TestString(t *testing.T) {
	if s := (account.Step{Transport: "wg", Port: 2408}); Label(s) != "wg:2408" {
		t.Fatal(Label(s))
	}
}
