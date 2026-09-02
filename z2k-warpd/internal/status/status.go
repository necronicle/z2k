// Package status — status.json: единственный источник правды о туннеле для
// панели, меню и z2k-warp.sh. Пишет только демон, атомарно; читатели никогда
// ничего не пробуют сами. Файл живёт в tmpfs.
package status

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Коды last_error. Панель переводит их в человеческий текст; демон — не.
const (
	ErrRegisterBlocked = "register_blocked" // API недоступен ни напрямую, ни через релей
	ErrDeviceRevoked   = "device_revoked"   // GET /reg → 401/404
	ErrNoEndpoint      = "no_endpoint"      // ни один WG-порт, ни h2
	ErrTunFailed       = "tun_failed"       // нет /dev/net/tun или настройка не удалась
	// ErrNoTransit — сессия встаёт (handshake/CONNECT прошли), но сквозная
	// проба не проходит: туннель не возит. Отдельно от no_endpoint, потому
	// что лечится это иначе — сменой ступени, а не «провайдер режет WARP».
	ErrNoTransit = "no_transit"
)

// Status — содержимое status.json.
type Status struct {
	Ready        bool   `json:"ready"`
	Transport    string `json:"transport"`
	Endpoint     string `json:"endpoint"`
	Iface        string `json:"iface"`
	Addr         string `json:"addr"`
	HandshakeAge int    `json:"handshake_age"` // сек; -1 = handshake не было
	Rx           uint64 `json:"rx"`
	Tx           uint64 `json:"tx"`
	LastError    string `json:"last_error"`
	LadderStep   int    `json:"ladder_step"`
	Since        int64  `json:"since"` // unix: с какого момента текущее состояние
	PID          int    `json:"pid"`
	// MemKB — RSS демона в КБ. Панель и диагностика показывают его, чтобы
	// вопрос «почему WARP ест сто мегабайт» закрывался взглядом, а не htop
	// (поле 2026-09-02: юзер с 118 МБ RSS, замер показал буферы по 64 КБ на пакет).
	MemKB int `json:"mem_kb"`
}

// Writer пишет статус не чаще MinInterval; отложенное значение всё равно
// доезжает — последнее всегда побеждает.
type Writer struct {
	Path        string
	MinInterval time.Duration

	mu      sync.Mutex
	last    time.Time
	pending *Status
	timer   *time.Timer
}

// Write записывает s сейчас или откладывает до конца интервала.
func (w *Writer) Write(s Status) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	now := time.Now()
	if w.MinInterval > 0 && now.Sub(w.last) < w.MinInterval {
		cp := s
		w.pending = &cp
		if w.timer == nil {
			w.timer = time.AfterFunc(w.MinInterval-now.Sub(w.last), w.flushPending)
		}
		return nil
	}
	w.last = now
	return write(w.Path, s)
}

func (w *Writer) flushPending() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.timer = nil
	if w.pending == nil {
		return
	}
	s := *w.pending
	w.pending = nil
	w.last = time.Now()
	_ = write(w.Path, s)
}

// Flush записывает отложенное значение немедленно (перед выходом демона).
func (w *Writer) Flush() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.timer != nil {
		w.timer.Stop()
		w.timer = nil
	}
	if w.pending == nil {
		return nil
	}
	s := *w.pending
	w.pending = nil
	w.last = time.Now()
	return write(w.Path, s)
}

// Remove удаляет статус-файл (демон остановлен — статуса нет).
func (w *Writer) Remove() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.timer != nil {
		w.timer.Stop()
		w.timer = nil
	}
	w.pending = nil
	_ = os.Remove(w.Path)
}

func write(path string, s Status) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Read читает status.json.
func Read(path string) (*Status, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Status
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	return &s, nil
}
