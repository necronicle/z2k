package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// Event — одна строка структурного журнала (спека v2, §6.1). Поля с omitempty:
// строка события содержит только то, что для него имеет смысл.
type Event struct {
	TS      string `json:"ts"`
	Ev      string `json:"ev"`
	SID     string `json:"sid,omitempty"`
	Install string `json:"install,omitempty"`
	IP      string `json:"ip,omitempty"`
	ASN     uint32 `json:"asn,omitempty"`
	Proto   string `json:"proto,omitempty"`
	DurMS   int64  `json:"dur_ms,omitempty"`
	RX      int64  `json:"rx,omitempty"`
	TX      int64  `json:"tx,omitempty"`
	Streams int    `json:"streams,omitempty"`
	Reason  string `json:"reason,omitempty"`
	Detail  string `json:"detail,omitempty"`
}

type eventSink interface {
	Emit(Event)
}

type nopEvents struct{}

func (nopEvents) Emit(Event) {}

// Глобальный сток событий. По умолчанию ничего не пишет; main() подменяет
// на файловый, тесты — на memEvents. Доступ атомарный: сессии дописывают
// закрытие уже после того, как тест сменил сток.
var eventsSink atomic.Value

func init() { setEvents(nopEvents{}) }

func setEvents(s eventSink) { eventsSink.Store(&s) }

func emitEvent(ev Event) { (*eventsSink.Load().(*eventSink)).Emit(ev) }

// eventWriteErrors — счётчик неудачных записей; писатель никогда не роняет
// релей из-за диска, но и не молчит: значение уходит в /metrics.
var eventWriteErrors atomic.Int64

// fileEvents пишет события в файл дня и держит не больше keep файлов.
type fileEvents struct {
	mu   sync.Mutex
	dir  string
	keep int
	day  string
	f    *os.File
	now  func() time.Time
}

func newFileEvents(dir string, keep int) (*fileEvents, error) {
	if keep < 1 {
		keep = 1
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("каталог событий %s: %w", dir, err)
	}
	probe := filepath.Join(dir, ".events-probe")
	if err := os.WriteFile(probe, nil, 0o644); err != nil {
		return nil, fmt.Errorf("каталог событий %s недоступен для записи: %w", dir, err)
	}
	_ = os.Remove(probe)
	return &fileEvents{dir: dir, keep: keep, now: time.Now}, nil
}

func (e *fileEvents) Emit(ev Event) {
	now := e.now().UTC()
	if ev.TS == "" {
		ev.TS = now.Format(time.RFC3339Nano)
	}
	line, err := json.Marshal(ev)
	if err != nil {
		eventWriteErrors.Add(1)
		return
	}
	line = append(line, '\n')

	e.mu.Lock()
	defer e.mu.Unlock()
	day := now.Format("2006-01-02")
	if e.f == nil || day != e.day {
		if err := e.rotateLocked(day); err != nil {
			eventWriteErrors.Add(1)
			return
		}
	}
	if _, err := e.f.Write(line); err != nil {
		eventWriteErrors.Add(1)
	}
}

// rotateLocked открывает файл дня и удаляет всё старше keep файлов.
func (e *fileEvents) rotateLocked(day string) error {
	if e.f != nil {
		_ = e.f.Close()
		e.f = nil
	}
	f, err := os.OpenFile(filepath.Join(e.dir, "events-"+day+".jsonl"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	e.f, e.day = f, day
	names, _ := filepath.Glob(filepath.Join(e.dir, "events-*.jsonl"))
	sort.Strings(names) // имена с датой ISO сортируются хронологически
	for len(names) > e.keep {
		_ = os.Remove(names[0])
		names = names[1:]
	}
	return nil
}

func (e *fileEvents) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.f == nil {
		return nil
	}
	err := e.f.Close()
	e.f = nil
	return err
}
