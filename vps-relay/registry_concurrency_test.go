package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// get обязана отдавать КОПИЮ, а не указатель в карту.
//
// Раньше отдавался указатель, и горячий путь аутентификации читал e.Revoked
// уже после того, как RLock отпущен, — а setRevoked писал это же поле под
// write-lock. Гонка ровно на поле-рубильнике: отзыв мог не увидеться
// соединением, которое аутентифицируется в этот момент, то есть kill-switch
// не срабатывал именно тогда, когда им пользуются.
func TestGetReturnsCopyNotPointer(t *testing.T) {
	reg = &registry{m: map[string]*regEntry{}, path: ""}
	reg.m["abc"] = &regEntry{Pubkey: "k", Revoked: false}

	got := reg.get("abc")
	if got == nil {
		t.Fatal("запись должна найтись")
	}
	if got == reg.m["abc"] {
		t.Fatal("get вернула указатель в карту — это и есть гонка")
	}

	// Правка копии не должна протекать в реестр.
	got.Revoked = true
	if reg.m["abc"].Revoked {
		t.Fatal("мутация копии просочилась в карту")
	}

	// И наоборот: изменение реестра не должно менять уже отданную копию.
	reg.setRevoked("abc", true)
	if got2 := reg.get("abc"); !got2.Revoked {
		t.Fatal("setRevoked не отразился на новых чтениях")
	}
}

func TestGetMissingReturnsNil(t *testing.T) {
	reg = &registry{m: map[string]*regEntry{}, path: ""}
	if reg.get("нет-такого") != nil {
		t.Fatal("для отсутствующей записи ожидали nil")
	}
}

// Чтения не должны блокироваться записью на диск, а сами записи обязаны
// оставаться упорядоченными: persistLocked маршалит под rg.mu и берёт
// writeMu, отдавая наружу функцию, которая пишет уже без rg.mu.
// Здесь проверяем главное следствие — параллельная работа не ломает файл и
// не теряет записи.
func TestConcurrentUpsertKeepsRegistryConsistent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "registry.json")
	reg = &registry{m: map[string]*regEntry{}, path: path}

	const n = 64
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := installIDFor(i)
			if created, ok := reg.upsert(id, "pk-"+id); !ok || !created {
				t.Errorf("upsert(%s): created=%v ok=%v", id, created, ok)
			}
		}(i)
	}
	wg.Wait()

	if len(reg.m) != n {
		t.Fatalf("в памяти ожидали %d записей, получили %d", n, len(reg.m))
	}

	// Файл на диске обязан быть валидным JSON — незавершённой записи или
	// перемешанных снимков быть не должно.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("реестр не прочитался: %v", err)
	}
	var onDisk map[string]*regEntry
	if err := json.Unmarshal(data, &onDisk); err != nil {
		t.Fatalf("реестр на диске — не валидный JSON: %v", err)
	}
	// Последняя выигравшая запись содержит все n: снимки сериализованы
	// writeMu в том же порядке, в каком маршалились под rg.mu.
	if len(onDisk) != n {
		t.Fatalf("на диске ожидали %d записей, получили %d — снимки легли не по порядку", n, len(onDisk))
	}
}

// Отзыв тоже пишется на диск и переживает перечитывание.
func TestSetRevokedPersists(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "registry.json")
	reg = &registry{m: map[string]*regEntry{}, path: path}

	id := installIDFor(1)
	if _, ok := reg.upsert(id, "pk"); !ok {
		t.Fatal("upsert не прошёл")
	}
	if !reg.setRevoked(id, true) {
		t.Fatal("setRevoked не нашёл запись")
	}
	if n, err := reg.reload(); err != nil || n != 1 {
		t.Fatalf("reload: n=%d err=%v", n, err)
	}
	if e := reg.get(id); e == nil || !e.Revoked {
		t.Fatal("флаг отзыва не пережил запись+перечитывание")
	}
}

func TestSetRevokedMissingReturnsFalse(t *testing.T) {
	reg = &registry{m: map[string]*regEntry{}, path: ""}
	if reg.setRevoked("нет-такого", true) {
		t.Fatal("для отсутствующей записи ожидали false")
	}
}

// installIDFor даёт валидный и УНИКАЛЬНЫЙ install_id (validInstallID требует
// ровно 32 hex-символа): 24 нуля + 8 hex-разрядов номера.
func installIDFor(i int) string {
	return fmt.Sprintf("%024d%08x", 0, i)
}
