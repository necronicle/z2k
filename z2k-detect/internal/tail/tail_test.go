package tail

// Охраняет фиксы 2026-08-14 по двум обещаниям из заголовка пакета, которые
// код не выполнял:
//
//  1. «surviving truncation» — усечение (logrotate copytruncate, AGH режет
//     querylog.json на месте) не детектировалось вовсе: inode тот же,
//     offset за концом файла, чтение возвращает EOF, и события молча
//     пропадают, пока файл не дорастёт до старой позиции.
//  2. «surviving … brief disappearance» — openFile закрывал старый файл ДО
//     открытия нового; провал os.Open оставлял reader на закрытом файле,
//     следующий Read давал не-EOF ошибку, и хвост умирал вместе с демоном.

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// collect reads lines until want lines arrived or the deadline passes.
func collect(t *testing.T, lines <-chan string, want int, d time.Duration) []string {
	t.Helper()
	var got []string
	deadline := time.After(d)
	for len(got) < want {
		select {
		case l, ok := <-lines:
			if !ok {
				t.Fatalf("канал закрылся, получено %d из %d: %v", len(got), want, got)
			}
			got = append(got, l)
		case <-deadline:
			t.Fatalf("такймаут: получено %d из %d: %v", len(got), want, got)
		}
	}
	return got
}

func TestFollowSurvivesTruncation(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "log")
	if err := os.WriteFile(p, []byte("first\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	lines, errs := Follow(ctx, p, Options{
		PollInterval:     50 * time.Millisecond,
		ReopenCheckEvery: 100 * time.Millisecond,
	})
	go func() {
		if err, ok := <-errs; ok && err != nil {
			t.Errorf("tail умер: %v", err)
		}
	}()

	_ = collect(t, lines, 1, 3*time.Second)

	// Усечение на месте: inode прежний, файл короче старой позиции.
	if err := os.Truncate(p, 0); err != nil {
		t.Fatal(err)
	}
	// Дать проверке размера случиться до записи новой строки: если писать
	// сразу, файл может дорасти до старого offset'а и замаскировать дефект.
	time.Sleep(300 * time.Millisecond)
	f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("after-truncate\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()

	got := collect(t, lines, 1, 5*time.Second)
	if got[0] != "after-truncate" {
		t.Fatalf("после усечения ожидалась строка after-truncate, получено %q", got[0])
	}
}

func TestFollowSurvivesRotation(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "log")
	if err := os.WriteFile(p, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	lines, errs := Follow(ctx, p, Options{
		PollInterval:     50 * time.Millisecond,
		ReopenCheckEvery: 100 * time.Millisecond,
	})
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err, ok := <-errs; ok && err != nil {
			t.Errorf("tail умер на ротации: %v", err)
		}
	}()

	_ = collect(t, lines, 1, 3*time.Second)

	// Классическая ротация: rename + новый файл на том же пути.
	if err := os.Rename(p, p+".1"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("rotated\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := collect(t, lines, 1, 5*time.Second)
	if got[0] != "rotated" {
		t.Fatalf("после ротации ожидалась строка rotated, получено %q", got[0])
	}
}
