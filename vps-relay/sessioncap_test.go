package main

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
)

func withCap(n int, fn func()) {
	old := *maxSessions
	*maxSessions = n
	liveSessions.Store(0)
	refusedTotal.Store(0)
	defer func() { *maxSessions = old; liveSessions.Store(0) }()
	fn()
}

// Потолка не было вовсе: при исчерпании памяти релей убивал OOM, и ложились ВСЕ
// туннели разом. Проверяем, что сверх потолка отказывают, а не принимают.
func TestSessionCapRefusesOverLimit(t *testing.T) {
	withCap(2, func() {
		for i := 1; i <= 2; i++ {
			if ok, _ := acquireSession(); !ok {
				t.Fatalf("сессия %d должна была поместиться", i)
			}
		}
		ok, retry := acquireSession()
		if ok {
			t.Fatal("третья сессия при потолке 2 не должна помещаться")
		}
		if retry < 30 || retry > 90 {
			t.Fatalf("время повтора вне диапазона 30–90: %d", retry)
		}
	})
}

// Освободившееся место обязано снова становиться доступным, иначе потолок
// превращается в счётчик всех подключений за жизнь процесса.
func TestSessionCapReleasesSlot(t *testing.T) {
	withCap(1, func() {
		if ok, _ := acquireSession(); !ok {
			t.Fatal("первая сессия должна поместиться")
		}
		if ok, _ := acquireSession(); ok {
			t.Fatal("вторая при потолке 1 не должна помещаться")
		}
		releaseSession()
		if ok, _ := acquireSession(); !ok {
			t.Fatal("после освобождения место обязано появиться")
		}
	})
}

// Ноль означает «без потолка»: узел может вырасти, и зашитое число станет
// вредным.
func TestSessionCapZeroMeansUnlimited(t *testing.T) {
	withCap(0, func() {
		for i := 0; i < 1000; i++ {
			if ok, _ := acquireSession(); !ok {
				t.Fatalf("при нулевом потолке отказов быть не должно (i=%d)", i)
			}
		}
	})
}

// Потолок обязан держать под ОДНОВРЕМЕННЫМИ попытками: между проверкой и
// занятием места на двух ядрах помещается сколько угодно соединений, и наивная
// реализация протекала бы ровно под той нагрузкой, ради которой написана.
func TestSessionCapHoldsUnderConcurrency(t *testing.T) {
	// Нагрузка подобрана ЗАМЕРОМ, а не на глаз. Первая версия теста пускала
	// 500 горутин в один заход и наивную реализацию (проверить, потом занять)
	// НЕ ловила: горутины успевали отработать почти последовательно. Двадцать
	// заходов по 2000 ловят её устойчиво — превышение выходит на 51 при
	// потолке 50. Тест, который не отличает правильную реализацию от
	// сломанной, не тест.
	withCap(50, func() {
		worst := int64(0)
		for round := 0; round < 20; round++ {
			liveSessions.Store(0)
			refusedTotal.Store(0)
			var wg sync.WaitGroup
			for i := 0; i < 2000; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					acquireSession()
				}()
			}
			wg.Wait()
			if v := liveSessions.Load(); v > worst {
				worst = v
			}
		}
		if worst != 50 {
			t.Fatalf("при потолке 50 держится %d — потолок протекает", worst)
		}
	})
}

// Время повтора обязано РАЗЛИЧАТЬСЯ. Отвергнутые — уже сгустившаяся группа:
// одинаковое время повтора назначает следующий всплеск на ту же секунду.
func TestRetryAfterIsJittered(t *testing.T) {
	seen := map[int]bool{}
	for i := 0; i < 200; i++ {
		v := retryAfterSeconds()
		if v < 30 || v > 90 {
			t.Fatalf("время повтора вне диапазона: %d", v)
		}
		seen[v] = true
	}
	if len(seen) < 10 {
		t.Fatalf("разброса нет: всего %d различных значений", len(seen))
	}
}

// Отказ обязан быть ЯВНЫМ: 503 и Retry-After, а не молча закрытое соединение —
// для клиента это неотличимо от обрыва.
func TestRefusalIsExplicitHTTP(t *testing.T) {
	withCap(1, func() {
		if ok, _ := acquireSession(); !ok {
			t.Fatal("первая сессия должна поместиться")
		}
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/ws", nil)
		req.Header.Set("Upgrade", "websocket")
		handleWS(req.Context(), rec, req)

		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("ждал 503, получил %d", rec.Code)
		}
		ra := rec.Header().Get("Retry-After")
		if ra == "" {
			t.Fatal("Retry-After не проставлен — клиент не знает, когда прийти")
		}
		if v, err := strconv.Atoi(ra); err != nil || v < 30 || v > 90 {
			t.Fatalf("Retry-After некорректен: %q", ra)
		}
	})
}
