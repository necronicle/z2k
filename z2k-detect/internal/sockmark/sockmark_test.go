package sockmark_test

import (
	"net"
	"runtime"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/sockmark"
)

// Метка — оптимизация, а не условие работы: без прав на SO_MARK (мак, раннер
// CI) подключение обязано пройти как обычно, а не упасть с EPERM.
func TestControlDoesNotBreakDial(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			c.Close()
		}
	}()
	d := net.Dialer{Control: sockmark.Control, Timeout: 5 * time.Second}
	c, err := d.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("подключение с меткой сорвалось: %v", err)
	}
	c.Close()
}

func TestSupportedOnlyOnLinux(t *testing.T) {
	if got, want := sockmark.Supported(), runtime.GOOS == "linux"; got != want {
		t.Fatalf("Supported() = %v на %s, ожидалось %v", got, runtime.GOOS, want)
	}
}

func TestParsePolicyMark(t *testing.T) {
	t.Run("Z2K_POL include mode", func(t *testing.T) {
		post := "-P POSTROUTING ACCEPT\n-A POSTROUTING -o ppp0 -j Z2K_POL\n"
		zpol := "-N Z2K_POL\n-A Z2K_POL -m mark --mark 0x40000000/0x40000000 -j RETURN\n-A Z2K_POL -m mark ! --mark 0xffffaab/0x0fffffff -j CONNMARK --set-xmark 0x20000000/0x20000000\n"
		mark, ok := sockmark.ParsePolicyMark(post, zpol)
		if !ok || mark != 0x0ffffaab {
			t.Fatalf("got (%#x, %v), want (0x0ffffaab, true)", mark, ok)
		}
	})

	t.Run("legacy direct POSTROUTING include rule with prefix bang", func(t *testing.T) {
		post := "-A POSTROUTING -o eth0 ! -m mark --mark 0x12345/0x0fffffff -j CONNMARK --set-xmark 0x20000000/0x20000000\n"
		mark, ok := sockmark.ParsePolicyMark(post, "")
		if !ok || mark != 0x12345 {
			t.Fatalf("got (%#x, %v), want (0x12345, true)", mark, ok)
		}
	})

	t.Run("exclude mode returns false / 0", func(t *testing.T) {
		post := "-A POSTROUTING -o ppp0 -m mark --mark 0xffffaab/0x0fffffff -j CONNMARK --set-xmark 0x20000000/0x20000000\n"
		mark, ok := sockmark.ParsePolicyMark(post, "")
		if ok || mark != 0 {
			t.Fatalf("got (%#x, %v), want (0, false)", mark, ok)
		}
	})

	t.Run("orphan Z2K_POL without POSTROUTING jump returns false / 0", func(t *testing.T) {
		post := "-P POSTROUTING ACCEPT\n"
		zpol := "-N Z2K_POL\n-A Z2K_POL -m mark ! --mark 0xffffaab/0x0fffffff -j CONNMARK --set-xmark 0x20000000/0x20000000\n"
		mark, ok := sockmark.ParsePolicyMark(post, zpol)
		if ok || mark != 0 {
			t.Fatalf("orphan Z2K_POL must not be active: got (%#x, %v), want (0, false)", mark, ok)
		}
	})

	t.Run("empty returns false", func(t *testing.T) {
		mark, ok := sockmark.ParsePolicyMark("", "")
		if ok || mark != 0 {
			t.Fatalf("got (%#x, %v), want (0, false)", mark, ok)
		}
	})
}

func TestControlWithMarkZeroAndNonZero(t *testing.T) {
	if fn := sockmark.ControlWithMark(0); fn != nil {
		t.Fatal("ControlWithMark(0) != nil, want nil")
	}
	ctrl := sockmark.ControlWithMark(0x0ffffaab)
	if runtime.GOOS == "linux" && ctrl == nil {
		t.Fatal("ControlWithMark(0x0ffffaab) = nil on linux")
	}
	if runtime.GOOS != "linux" {
		return
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		if c, err := ln.Accept(); err == nil {
			c.Close()
		}
	}()
	c, err := (&net.Dialer{Control: ctrl, Timeout: 2 * time.Second}).Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("Dial с ControlWithMark сорвался: %v", err)
	}
	c.Close()
}
