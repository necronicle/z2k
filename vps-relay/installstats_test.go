package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// resetInstalls даёт каждому тесту чистый учёт: карта глобальная.
func resetInstalls(t *testing.T) {
	t.Helper()
	installs.mu.Lock()
	installs.m = map[string]*installStat{}
	installs.mu.Unlock()
}

// withInts временно подменяет флаги-числа и возвращает их обратно.
func withInts(t *testing.T, pairs ...interface{}) {
	t.Helper()
	for i := 0; i+1 < len(pairs); i += 2 {
		p := pairs[i].(*int)
		old := *p
		*p = pairs[i+1].(int)
		t.Cleanup(func() { *p = old })
	}
}

const testID = "0123456789abcdef0123456789abcdef"

func TestDistinctIPsCounted(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 0, perInstallMaxSessions, 0, installWarnIPs, 0)

	for _, ip := range []string{"1.1.1.1", "2.2.2.2", "1.1.1.1", "3.3.3.3"} {
		if ok, why := installs.begin(testID, ip, nil); !ok {
			t.Fatalf("begin(%s) отказал: %s", ip, why)
		}
	}
	_, live, list := installs.snapshot(0)
	if len(list) != 1 {
		t.Fatalf("установок в сводке: %d, ожидалась 1", len(list))
	}
	// Повтор того же адреса не должен считаться новым — иначе домашний роутер,
	// который переподключается каждые пару минут, выглядел бы как раздача.
	if list[0].IPs != 3 {
		t.Errorf("разных адресов: %d, ожидалось 3", list[0].IPs)
	}
	if live != 4 || list[0].Sessions != 4 {
		t.Errorf("сессий: live=%d sess=%d, ожидалось 4 и 4", live, list[0].Sessions)
	}
	if list[0].Peak != 4 {
		t.Errorf("пик: %d, ожидалось 4", list[0].Peak)
	}
}

func TestDailyRollover(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 0, perInstallMaxSessions, 0, installWarnIPs, 0)

	installs.begin(testID, "1.1.1.1", nil)
	installs.begin(testID, "2.2.2.2", nil)
	installs.end(testID, nil, 1000, 2000)

	// Отматываем сутки назад: смена суток должна обнулить накопленное, но НЕ
	// живое число сессий — оно описывает текущий момент, а не сутки.
	installs.mu.Lock()
	installs.m[testID].day--
	installs.mu.Unlock()

	installs.begin(testID, "9.9.9.9", nil)

	_, _, list := installs.snapshot(0)
	if list[0].IPs != 1 {
		t.Errorf("после смены суток адресов: %d, ожидался 1", list[0].IPs)
	}
	if list[0].Sessions != 1 {
		t.Errorf("после смены суток сессий: %d, ожидалась 1", list[0].Sessions)
	}
	if list[0].Bytes != 0 {
		t.Errorf("после смены суток объём: %d, ожидался 0", list[0].Bytes)
	}
	if list[0].Live != 2 {
		t.Errorf("живых сессий: %d, ожидалось 2 — смена суток их обнулять не должна", list[0].Live)
	}
}

// Тот, от кого мы защищаемся, может ротировать адреса. Если карта не
// ограничена, он раздувает нам память запросами — то есть защита сама даёт
// рычаг против нас.
func TestIPMapBounded(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 0, perInstallMaxSessions, 0, installWarnIPs, 0)

	for i := 0; i < maxTrackedIPs+200; i++ {
		installs.begin(testID, "10.0."+strconv.Itoa(i/256)+"."+strconv.Itoa(i%256), nil)
	}
	_, _, list := installs.snapshot(0)
	if list[0].IPs != maxTrackedIPs {
		t.Errorf("адресов в карте: %d, ожидался потолок %d", list[0].IPs, maxTrackedIPs)
	}
	if !list[0].Capped {
		t.Error("признак упирания в потолок не выставлен — в сводке это будет выглядеть как ровно 256 адресов")
	}
}

func TestMaxIPsRejects(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 3, perInstallMaxSessions, 0, installWarnIPs, 0)

	for i := 1; i <= 3; i++ {
		if ok, why := installs.begin(testID, "10.0.0."+strconv.Itoa(i), nil); !ok {
			t.Fatalf("адрес %d отвергнут раньше времени: %s", i, why)
		}
	}
	ok, why := installs.begin(testID, "10.0.0.4", nil)
	if ok {
		t.Fatal("четвёртый адрес пропущен, хотя потолок 3")
	}
	if why == "" {
		t.Error("причина отказа не заполнена — в логе будет нечего читать")
	}
	// Отвергнутая попытка всё равно улика: адрес должен остаться в счётчике.
	_, _, list := installs.snapshot(0)
	if list[0].IPs != 4 {
		t.Errorf("адресов после отказа: %d, ожидалось 4 — отвергнутый тоже улика", list[0].IPs)
	}
	// Без счётчика отказов по сводке нельзя понять, срабатывает ли отсечка
	// вообще или порог просто выставлен слишком высоко.
	if list[0].Rejected != 1 {
		t.Errorf("отказов: %d, ожидался 1", list[0].Rejected)
	}
	if list[0].FirstSeen == 0 {
		t.Error("время первого появления не заполнено — «появилась минуту назад и уже сотня адресов» не отличить от старой установки")
	}
}

// Запись того, кто только долбится в потолок и ни разу не прошёл, обязана
// пережить уборку: иначе улики исчезают ровно на том, от кого защищаемся.
func TestRejectedInstallSurvivesGC(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 0, perInstallMaxSessions, 1, installWarnIPs, 0)

	installs.begin(testID, "1.1.1.1", nil) // занимает единственное место
	for i := 0; i < 5; i++ {
		if ok, _ := installs.begin(testID, "1.1.1.1", nil); ok {
			t.Fatal("сессия сверх потолка пропущена")
		}
	}
	if n := installs.gc(48 * time.Hour); n != 0 {
		t.Errorf("уборщик снёс %d записей, а не должен был ни одной", n)
	}
	_, _, list := installs.snapshot(0)
	if len(list) != 1 || list[0].Rejected != 5 {
		t.Errorf("отказов: %v, ожидалось 5", list)
	}
}

func TestSessionCapRejectsAndReleases(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 0, perInstallMaxSessions, 2, installWarnIPs, 0)

	if ok, _ := installs.begin(testID, "1.1.1.1", nil); !ok {
		t.Fatal("первая сессия отвергнута")
	}
	if ok, _ := installs.begin(testID, "1.1.1.1", nil); !ok {
		t.Fatal("вторая сессия отвергнута")
	}
	if ok, _ := installs.begin(testID, "1.1.1.1", nil); ok {
		t.Fatal("третья сессия пропущена, хотя потолок 2")
	}
	// Освобождение должно возвращать место — иначе установка залипает навсегда
	// после первого же всплеска.
	installs.end(testID, nil, 0, 0)
	if ok, why := installs.begin(testID, "1.1.1.1", nil); !ok {
		t.Fatalf("после освобождения место не вернулось: %s", why)
	}
}

func TestGCDropsIdleKeepsLive(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 0, perInstallMaxSessions, 0, installWarnIPs, 0)

	idle := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	installs.begin(idle, "1.1.1.1", nil)
	installs.end(idle, nil, 0, 0)
	installs.mu.Lock()
	installs.m[idle].lastSeen = time.Now().Add(-72 * time.Hour).Unix()
	installs.mu.Unlock()

	installs.begin(testID, "2.2.2.2", nil) // живая, не трогать

	if n := installs.gc(48 * time.Hour); n != 1 {
		t.Errorf("убрано записей: %d, ожидалась 1", n)
	}
	total, _, _ := installs.snapshot(0)
	if total != 1 {
		t.Errorf("осталось записей: %d, ожидалась 1 (живая)", total)
	}
}

// Отзыв обязан рвать УЖЕ ПОДНЯТЫЙ туннель. Раньше флаг проверялся только при
// поднятии новой сессии, и отозванный клиент продолжал работать часами.
func TestKillInstallClosesLiveSessions(t *testing.T) {
	resetInstalls(t)
	withInts(t, installMaxIPs, 0, perInstallMaxSessions, 0, installWarnIPs, 0)

	s1, _, c1 := newTestSession(t)
	defer c1()
	s2, _, c2 := newTestSession(t)
	defer c2()

	installs.begin(testID, "1.1.1.1", s1)
	installs.begin(testID, "2.2.2.2", s2)

	if n := installs.killInstall(testID); n != 2 {
		t.Fatalf("оборвано сессий: %d, ожидалось 2", n)
	}
	for i, s := range []*session{s1, s2} {
		select {
		case <-s.done:
		case <-time.After(2 * time.Second):
			t.Errorf("сессия %d не оборвана", i+1)
		}
	}
	// Повторный отзыв не должен ни падать, ни считать те же сессии снова.
	if n := installs.killInstall(testID); n != 2 {
		t.Logf("повторный отзыв вернул %d (соединения ещё в карте до end) — не ошибка", n)
	}
}

// Регрессия: до правки способа выставить Revoked не существовало, а ручная
// правка registry.json стиралась первой же успешной регистрацией, которая
// перезаписывает файл из памяти.
func TestRevokeSurvivesLaterRegistration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "registry.json")
	initRegistry(path)

	victim := testID
	other := "ffffffffffffffffffffffffffffffff"
	reg.upsert(victim, "cHVia2V5MQ==")

	if !reg.setRevoked(victim, true) {
		t.Fatal("setRevoked не нашёл установку")
	}

	// Чужая регистрация перезаписывает файл целиком — флаг обязан уцелеть.
	reg.upsert(other, "cHVia2V5Mg==")

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("прочитать реестр: %v", err)
	}
	var m map[string]*regEntry
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("разобрать реестр: %v", err)
	}
	if m[victim] == nil || !m[victim].Revoked {
		t.Error("отзыв стёрт следующей регистрацией — ровно тот баг, который чинили")
	}
	if m[other] == nil {
		t.Error("новая установка не сохранилась")
	}

	// Снятие отзыва тоже обязано доезжать до файла.
	reg.setRevoked(victim, false)
	data, _ = os.ReadFile(path)
	_ = json.Unmarshal(data, &m)
	if m[victim].Revoked {
		t.Error("снятие отзыва не сохранилось")
	}
}

// Правка файла руками применяется без перезапуска: перезапуск рвёт все живые
// туннели разом и ради одной записи неприемлем.
func TestReloadPicksUpManualEdit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "registry.json")
	initRegistry(path)
	reg.upsert(testID, "cHVia2V5MQ==")

	if e := reg.get(testID); e == nil || e.Revoked {
		t.Fatal("исходно установка должна быть не отозвана")
	}

	edited := map[string]*regEntry{
		testID: {Pubkey: "cHVia2V5MQ==", Revoked: true, CreatedAt: 1},
	}
	data, _ := json.Marshal(edited)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("записать правку: %v", err)
	}

	n, err := reg.reload()
	if err != nil {
		t.Fatalf("перечитать: %v", err)
	}
	if n != 1 {
		t.Errorf("записей после перечитывания: %d, ожидалась 1", n)
	}
	if e := reg.get(testID); e == nil || !e.Revoked {
		t.Error("правка файла не подхватилась — ради неё пришлось бы перезапускать релей")
	}
	ids := reg.revokedIDs()
	if len(ids) != 1 || ids[0] != testID {
		t.Errorf("список отозванных: %v, ожидался один %s", ids, testID)
	}
}

// Битый файл не должен обнулять живой реестр: иначе одна опечатка в правке
// выкинула бы все установки разом.
func TestReloadKeepsRegistryOnBadFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "registry.json")
	initRegistry(path)
	reg.upsert(testID, "cHVia2V5MQ==")

	if err := os.WriteFile(path, []byte("{не json"), 0o600); err != nil {
		t.Fatalf("записать мусор: %v", err)
	}
	if _, err := reg.reload(); err == nil {
		t.Fatal("перечитывание битого файла прошло без ошибки")
	}
	if reg.get(testID) == nil {
		t.Error("реестр обнулён битым файлом — установки потеряны")
	}
}
