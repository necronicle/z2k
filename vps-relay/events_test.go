package main

import (
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// memEvents — сток для тестов других файлов: копит события в памяти.
type memEvents struct {
	mu   sync.Mutex
	list []Event
}

func (m *memEvents) Emit(ev Event) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if ev.TS == "" {
		ev.TS = time.Now().UTC().Format(time.RFC3339Nano)
	}
	m.list = append(m.list, ev)
}

func (m *memEvents) byEv(name string) []Event {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Event
	for _, e := range m.list {
		if e.Ev == name {
			out = append(out, e)
		}
	}
	return out
}

// wait ждёт, пока событий name станет не меньше n.
func (m *memEvents) wait(name string, n int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if len(m.byEv(name)) >= n {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return len(m.byEv(name)) >= n
}

func readLines(t *testing.T, path string) []Event {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var out []Event
	for _, ln := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if ln == "" {
			continue
		}
		var e Event
		if err := json.Unmarshal([]byte(ln), &e); err != nil {
			t.Fatalf("строка не JSON: %q: %v", ln, err)
		}
		out = append(out, e)
	}
	return out
}

func TestFileEvents_WritesJSONLine(t *testing.T) {
	dir := t.TempDir()
	fe, err := newFileEvents(dir, 30)
	if err != nil {
		t.Fatal(err)
	}
	fe.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC) }
	fe.Emit(Event{Ev: "session_open", SID: "abc", IP: "1.2.3.4", Proto: "v1"})
	if err := fe.Close(); err != nil {
		t.Fatal(err)
	}
	got := readLines(t, filepath.Join(dir, "events-2026-09-02.jsonl"))
	if len(got) != 1 || got[0].Ev != "session_open" || got[0].SID != "abc" || got[0].IP != "1.2.3.4" {
		t.Fatalf("неверная запись: %+v", got)
	}
	if !strings.HasPrefix(got[0].TS, "2026-09-02T10:00:00") {
		t.Fatalf("ts не выставлен из часов писателя: %q", got[0].TS)
	}
}

func TestFileEvents_RotatesByDayAndPrunes(t *testing.T) {
	dir := t.TempDir()
	// Три старых файла, потолок два: после первой записи остаётся два самых новых.
	for _, d := range []string{"2026-08-01", "2026-08-02", "2026-08-03"} {
		if err := os.WriteFile(filepath.Join(dir, "events-"+d+".jsonl"), []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	fe, err := newFileEvents(dir, 2)
	if err != nil {
		t.Fatal(err)
	}
	day := time.Date(2026, 9, 2, 23, 59, 59, 0, time.UTC)
	fe.now = func() time.Time { return day }
	fe.Emit(Event{Ev: "session_open"})
	day = day.Add(2 * time.Second) // 2026-09-03
	fe.Emit(Event{Ev: "session_close"})
	if err := fe.Close(); err != nil {
		t.Fatal(err)
	}
	names, _ := filepath.Glob(filepath.Join(dir, "events-*"))
	sort.Strings(names)
	var base []string
	for _, n := range names {
		base = append(base, filepath.Base(n))
	}
	// Старые дни удалены по потолку, вчерашний сжат, сегодняшний пишется.
	want := []string{"events-2026-09-02.jsonl.gz", "events-2026-09-03.jsonl"}
	if strings.Join(base, ",") != strings.Join(want, ",") {
		t.Fatalf("после ротации ожидались %v, получено %v", want, base)
	}
	if got := readLines(t, names[1]); len(got) != 1 || got[0].Ev != "session_close" {
		t.Fatalf("новый день получил не своё событие: %+v", got)
	}
	if got := readGzLines(t, names[0]); len(got) != 1 || got[0].Ev != "session_open" {
		t.Fatalf("сжатый вчерашний день: %+v", got)
	}
}

func readGzLines(t *testing.T, path string) []Event {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	var out []Event
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if line == "" {
			continue
		}
		var ev Event
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("строка %q: %v", line, err)
		}
		out = append(out, ev)
	}
	return out
}

// Штатные события стримов в файл не попадают (99,5 % объёма), ненормальные
// закрытия и всё остальное — попадают. Сток в памяти видит всё.
func TestFileEvents_DropsRoutineStreamEvents(t *testing.T) {
	dir := t.TempDir()
	fe, err := newFileEvents(dir, 30)
	if err != nil {
		t.Fatal(err)
	}
	fe.now = func() time.Time { return time.Date(2026, 9, 3, 10, 0, 0, 0, time.UTC) }
	fe.Emit(Event{Ev: "stream_open", SID: "a"})
	fe.Emit(Event{Ev: "stream_close", SID: "a", Reason: "eof"})
	fe.Emit(Event{Ev: "stream_close", SID: "a", Reason: "peer_close"})
	fe.Emit(Event{Ev: "stream_close", SID: "a", Reason: "session_close"})
	fe.Emit(Event{Ev: "stream_close", SID: "a", Reason: "queue_limit"})
	fe.Emit(Event{Ev: "stream_close", SID: "a", Reason: "peer_reset"})
	fe.Emit(Event{Ev: "session_close", SID: "a", Reason: "read_err"})
	fe.Emit(Event{Ev: "dial_fail", SID: "a", Reason: "dial_throttled"})
	if err := fe.Close(); err != nil {
		t.Fatal(err)
	}
	got := readLines(t, filepath.Join(dir, "events-2026-09-03.jsonl"))
	var evs []string
	for _, g := range got {
		evs = append(evs, g.Ev+":"+g.Reason)
	}
	want := "stream_close:queue_limit,stream_close:peer_reset,session_close:read_err,dial_fail:dial_throttled"
	if strings.Join(evs, ",") != want {
		t.Fatalf("в файле %v, ожидалось %s", evs, want)
	}
	m := &memEvents{}
	m.Emit(Event{Ev: "stream_open"})
	if len(m.byEv("stream_open")) != 1 {
		t.Fatal("сток в памяти обязан видеть штатные события стримов")
	}
}

// Файл, оставшийся несжатым после перезапуска посреди дня, сжимается при
// первой же ротации; сегодняшний не трогается.
func TestFileEvents_CompressesStaleOnStart(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "events-2026-09-01.jsonl"), []byte("{\"ev\":\"x\"}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	fe, err := newFileEvents(dir, 30)
	if err != nil {
		t.Fatal(err)
	}
	fe.now = func() time.Time { return time.Date(2026, 9, 3, 10, 0, 0, 0, time.UTC) }
	fe.Emit(Event{Ev: "session_open"})
	if err := fe.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "events-2026-09-01.jsonl.gz")); err != nil {
		t.Fatal("вчерашний файл не сжат:", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "events-2026-09-01.jsonl")); !os.IsNotExist(err) {
		t.Fatal("оригинал после сжатия остался")
	}
	if _, err := os.Stat(filepath.Join(dir, "events-2026-09-03.jsonl")); err != nil {
		t.Fatal("сегодняшний файл тронут:", err)
	}
}

func TestFileEvents_UnwritableDirDoesNotPanic(t *testing.T) {
	_, err := newFileEvents("/proc/no-such-dir/events", 30)
	if err == nil {
		t.Fatal("ожидалась ошибка на недоступном каталоге")
	}
}
