package main

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
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

// worthKeeping — что попадает в файл. Штатное открытие и закрытие стрима
// (eof, peer_close, закрытие вместе с сессией) — 99,5 % строк журнала
// (замер 02.09.2026: 1,58 млн из 1,59 млн, 274 МБ за день) при нулевой
// диагностической ценности: число стримов есть в session_close и в
// метриках. В файл идут сессии, отказы, дозвоны и только ненормальные
// закрытия стримов. Сток в памяти (тесты) видит всё.
func worthKeeping(ev Event) bool {
	switch ev.Ev {
	case "stream_open":
		return false
	case "stream_close":
		switch ev.Reason {
		case "eof", "peer_close", "session_close":
			return false
		}
	}
	return true
}

// fileEvents пишет события в файл дня и держит не больше keep суток.
// Файлы прошлых дней сжимаются gzip (на живых данных 10:1) и удаляются
// по старшинству; уборка идёт отдельной горутиной, чтобы не держать
// сессии на замке писателя во время сжатия.
type fileEvents struct {
	mu   sync.Mutex
	dir  string
	keep int
	day  string
	f    *os.File
	now  func() time.Time
	hk   sync.WaitGroup
	hkMu sync.Mutex
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
	if !worthKeeping(ev) {
		return
	}
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

// rotateLocked открывает файл дня и запускает уборку прошлых дней.
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
	e.hk.Add(1)
	go func() {
		defer e.hk.Done()
		e.housekeep()
	}()
	return nil
}

// housekeep — удалить дни старше keep, сжать несжатые файлы прошлых дней.
// Сначала удаление: незачем сжимать то, что сейчас уйдёт. Текущий день
// берётся у писателя в момент уборки, а не в момент запуска: две ротации
// подряд (полночь и перезапуск) не должны сжать файл, который уже пишется.
func (e *fileEvents) housekeep() {
	e.hkMu.Lock()
	defer e.hkMu.Unlock()
	e.mu.Lock()
	current := e.day
	e.mu.Unlock()
	names, _ := filepath.Glob(filepath.Join(e.dir, "events-*.jsonl*"))
	byDay := map[string][]string{}
	for _, n := range names {
		d := strings.TrimSuffix(strings.TrimSuffix(strings.TrimPrefix(filepath.Base(n), "events-"), ".gz"), ".jsonl")
		byDay[d] = append(byDay[d], n)
	}
	days := make([]string, 0, len(byDay))
	for d := range byDay {
		days = append(days, d)
	}
	sort.Strings(days) // даты ISO сортируются хронологически
	for len(days) > e.keep {
		for _, n := range byDay[days[0]] {
			_ = os.Remove(n)
		}
		days = days[1:]
	}
	for _, d := range days {
		if d >= current {
			continue
		}
		for _, n := range byDay[d] {
			if strings.HasSuffix(n, ".jsonl") {
				if err := gzipFile(n); err != nil {
					eventWriteErrors.Add(1)
				}
			}
		}
	}
}

// gzipFile — сжать src в src.gz и удалить src; при ошибке оригинал остаётся.
func gzipFile(src string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := src + ".gz.tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	zw := gzip.NewWriter(out)
	if _, err := io.Copy(zw, in); err != nil {
		zw.Close()
		out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := zw.Close(); err != nil {
		out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, src+".gz"); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Remove(src)
}

// Close закрывает файл дня и дожидается уборки.
func (e *fileEvents) Close() error {
	e.mu.Lock()
	var err error
	if e.f != nil {
		err = e.f.Close()
		e.f = nil
	}
	e.mu.Unlock()
	e.hk.Wait()
	return err
}
