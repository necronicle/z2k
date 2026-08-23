// Package logrot — лог демона с ротацией по размеру. Только tmpfs:
// 475 МБ за 17 часов на флешке — уже было.
package logrot

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Writer — io.Writer с ротацией: path → path.1, один запасной файл.
type Writer struct {
	Path string
	Max  int64

	mu   sync.Mutex
	f    *os.File
	size int64
}

// New открывает лог (создаёт каталог).
func New(path string, max int64) (*Writer, error) {
	w := &Writer{Path: path, Max: max}
	if err := w.open(); err != nil {
		return nil, err
	}
	return w, nil
}

func (w *Writer) open() error {
	if err := os.MkdirAll(filepath.Dir(w.Path), 0755); err != nil {
		return err
	}
	f, err := os.OpenFile(w.Path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	w.f, w.size = f, st.Size()
	return nil
}

func (w *Writer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return 0, os.ErrClosed
	}
	if w.Max > 0 && w.size+int64(len(p)) > w.Max {
		w.f.Close()
		os.Rename(w.Path, w.Path+".1")
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	n, err := w.f.Write(p)
	w.size += int64(n)
	return n, err
}

// Close закрывает файл.
func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return nil
	}
	err := w.f.Close()
	w.f = nil
	return err
}

// Logf — строка с меткой времени.
func (w *Writer) Logf(format string, args ...any) {
	fmt.Fprintf(w, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}
