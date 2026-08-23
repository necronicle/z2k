package status

import (
	"os"
	"path/filepath"
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
