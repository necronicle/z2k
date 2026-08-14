package main

// Охраняет фикс 2026-08-14 (находка код-ревью, уверенность 75).
//
// persistLocked захватывал writeMu, ЕЩЁ ДЕРЖА rg.mu. Пока первый писатель
// пишет файл, второй берёт rg.mu, упирается в writeMu и держит rg.mu всё
// время чужой дисковой записи — а за ним встаёт аутентификация всех живых
// туннелей (get берёт RLock). Разделение из 033bf5c вводилось ровно против
// этого, но одновременная регистрация его возвращала, а /register доступен
// всякому, кто знает общий секрет.
//
// Порядок снимков теперь держит номер, а не замок: мутация и маршалинг идут
// в одной секции rg.mu, поэтому больший номер включает всё из меньших, и
// устаревшую запись можно пропустить.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Главное свойство: persistLocked возвращает управление, НЕ удерживая writeMu.
// До фикса TryLock здесь проваливался — и вместе с ним стоял rg.mu.
func TestPersistLockedDoesNotHoldWriteMuAcrossReturn(t *testing.T) {
	dir := t.TempDir()
	rg := &registry{m: map[string]*regEntry{}, path: filepath.Join(dir, "registry.json")}
	rg.m["a"] = &regEntry{Pubkey: "k"}

	rg.mu.Lock()
	flush := rg.persistLocked()
	rg.mu.Unlock()
	if flush == nil {
		t.Fatal("ожидали функцию записи")
	}

	if !rg.writeMu.TryLock() {
		t.Fatal("writeMu удерживается после возврата persistLocked — второй писатель " +
			"встанет на нём, ДЕРЖА rg.mu, и заморозит аутентификацию всего парка")
	}
	rg.writeMu.Unlock()

	flush()
	if _, err := os.Stat(rg.path); err != nil {
		t.Fatalf("файл так и не записан: %v", err)
	}
}

// Пропуск устаревшего снимка: если более свежий уже лёг, старый не должен
// затирать его. Раньше это обеспечивалось порядком захвата writeMu.
func TestStaleSnapshotDoesNotOverwriteNewer(t *testing.T) {
	dir := t.TempDir()
	rg := &registry{m: map[string]*regEntry{}, path: filepath.Join(dir, "registry.json")}

	// Снимок 1: одна запись.
	rg.mu.Lock()
	rg.m["one"] = &regEntry{Pubkey: "k1"}
	flush1 := rg.persistLocked()
	rg.mu.Unlock()

	// Снимок 2: две записи.
	rg.mu.Lock()
	rg.m["two"] = &regEntry{Pubkey: "k2"}
	flush2 := rg.persistLocked()
	rg.mu.Unlock()

	// Второй писатель выиграл гонку и лёг первым.
	flush2()
	// Первый приходит следом — и обязан ничего не делать.
	flush1()

	var loaded map[string]*regEntry
	readJSON(t, rg.path, &loaded)
	if len(loaded) != 2 {
		t.Fatalf("на диске %d записей, ожидали 2 — устаревший снимок затёр свежий: %v",
			len(loaded), loaded)
	}
	if _, ok := loaded["two"]; !ok {
		t.Error("запись из более свежего снимка потеряна")
	}
}

// Провал записи не должен «съедать» номер: следующая попытка обязана пройти.
func TestFailedWriteDoesNotAdvanceSeq(t *testing.T) {
	dir := t.TempDir()
	// Путь внутри файла, а не каталога — MkdirAll и WriteFile обязаны упасть.
	blocker := filepath.Join(dir, "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	rg := &registry{m: map[string]*regEntry{}, path: filepath.Join(blocker, "sub", "registry.json")}

	rg.mu.Lock()
	rg.m["a"] = &regEntry{Pubkey: "k"}
	flushBad := rg.persistLocked()
	rg.mu.Unlock()
	flushBad() // обязан провалиться и НЕ сдвинуть written

	if rg.written != 0 {
		t.Fatalf("провалившаяся запись сдвинула written на %d — следующая была бы пропущена", rg.written)
	}

	// Чиним путь и пишем снова: снимок обязан лечь.
	rg.path = filepath.Join(dir, "registry.json")
	rg.mu.Lock()
	flushGood := rg.persistLocked()
	rg.mu.Unlock()
	flushGood()

	var loaded map[string]*regEntry
	readJSON(t, rg.path, &loaded)
	if _, ok := loaded["a"]; !ok {
		t.Fatal("после провала предыдущей записи следующая не прошла")
	}
}

func readJSON(t *testing.T, path string, into any) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("читаю %s: %v", path, err)
	}
	if err := json.Unmarshal(data, into); err != nil {
		t.Fatalf("разбираю %s: %v", path, err)
	}
}
