package logrot

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRotatesAtMax(t *testing.T) {
	p := filepath.Join(t.TempDir(), "warpd.log")
	w, err := New(p, 1000)
	if err != nil {
		t.Fatal(err)
	}
	line := strings.Repeat("x", 99) + "\n"
	for i := 0; i < 15; i++ { // 1500 байт
		if _, err := w.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	w.Close()
	st, err := os.Stat(p)
	if err != nil || st.Size() > 1000 {
		t.Fatalf("main log %v %v", st, err)
	}
	st1, err := os.Stat(p + ".1")
	if err != nil || st1.Size() == 0 {
		t.Fatalf("rotated log %v %v", st1, err)
	}
	if st.Size()+st1.Size() != 1500 {
		t.Fatalf("bytes lost: %d + %d", st.Size(), st1.Size())
	}
}

func TestLogfStampsTime(t *testing.T) {
	p := filepath.Join(t.TempDir(), "warpd.log")
	w, _ := New(p, 0)
	w.Logf("hello %d", 7)
	w.Close()
	b, _ := os.ReadFile(p)
	if !strings.HasSuffix(strings.TrimSpace(string(b)), " hello 7") || len(b) < 25 {
		t.Fatalf("%q", b)
	}
}
