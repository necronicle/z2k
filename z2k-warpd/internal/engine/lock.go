package engine

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

// ErrAlreadyRunning — движок уже запущен другим процессом.
var ErrAlreadyRunning = errors.New("another z2k-warpd is already running")

// acquireLock берёт эксклюзивный flock. Без него два экземпляра сосуществуют
// ровно до TUN: второй падает с «device or resource busy» — и по дороге
// (defer status.Remove) СНОСИТ status.json живого первого, а init кладёт в
// pidfile его мёртвый pid. Дальше selfheal каждые 25 с поднимает новый
// обречённый процесс, панель показывает «движок не запущен», маршрут
// снимается — при живом туннеле. Поле r-79.4, три диагностики.
//
// flock, а не pidfile: снимается ядром при любой смерти процесса, включая
// SIGKILL и OOM, так что мёртвый замок невозможен.
func acquireLock(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, ErrAlreadyRunning
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}
