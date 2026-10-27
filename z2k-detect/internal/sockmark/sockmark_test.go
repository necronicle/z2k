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
