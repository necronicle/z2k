package status

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestWriteIsAtomicAndReadable(t *testing.T) {
	p := filepath.Join(t.TempDir(), "status.json")
	w := &Writer{Path: p}
	if err := w.Write(Status{Ready: true, Transport: "wg", Endpoint: "8.6.112.0:2408", PID: 42}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("tmp left behind")
	}
	s, err := Read(p)
	if err != nil || !s.Ready || s.Transport != "wg" || s.PID != 42 {
		t.Fatalf("%+v %v", s, err)
	}
}

func TestWriteRateLimitedButLastWins(t *testing.T) {
	p := filepath.Join(t.TempDir(), "status.json")
	w := &Writer{Path: p, MinInterval: 200 * time.Millisecond}
	if err := w.Write(Status{LadderStep: 1}); err != nil {
		t.Fatal(err)
	}
	if err := w.Write(Status{LadderStep: 2}); err != nil { // внутри интервала — откладывается
		t.Fatal(err)
	}
	s, _ := Read(p)
	if s.LadderStep != 1 {
		t.Fatalf("early write leaked: %d", s.LadderStep)
	}
	time.Sleep(350 * time.Millisecond)
	s, _ = Read(p)
	if s.LadderStep != 2 {
		t.Fatalf("deferred write lost: %d", s.LadderStep)
	}
}

func TestFlushWritesPendingNow(t *testing.T) {
	p := filepath.Join(t.TempDir(), "status.json")
	w := &Writer{Path: p, MinInterval: time.Hour}
	w.Write(Status{LadderStep: 1})
	w.Write(Status{LadderStep: 2})
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	s, _ := Read(p)
	if s.LadderStep != 2 {
		t.Fatalf("flush did not write pending: %d", s.LadderStep)
	}
}

func TestReadMissing(t *testing.T) {
	if _, err := Read(filepath.Join(t.TempDir(), "nope.json")); err == nil {
		t.Fatal("want error")
	}
}

func TestMemKBRoundTrip(t *testing.T) {
	dir := t.TempDir()
	w := &Writer{Path: filepath.Join(dir, "s.json")}
	if err := w.Write(Status{MemKB: 12345}); err != nil {
		t.Fatal(err)
	}
	s, err := Read(w.Path)
	if err != nil {
		t.Fatal(err)
	}
	if s.MemKB != 12345 {
		t.Fatalf("mem_kb = %d, ждали 12345", s.MemKB)
	}
	b, _ := os.ReadFile(w.Path)
	if !strings.Contains(string(b), `"mem_kb":12345`) {
		t.Fatalf("в файле нет mem_kb: %s", b)
	}
}

func TestRSSKBOnLinuxIsPositive(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("RSS читается из /proc")
	}
	if RSSKB() <= 0 {
		t.Fatal("RSSKB() = 0 на linux")
	}
}
