package sniwl

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeClock — часы, которые двигает тест. Троттлинг на сутки иначе не
// проверить: ждать сутки в тесте нельзя, а ослабить окно ради теста значит
// проверять не то, что поедет на роутер.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newClock() *fakeClock {
	return &fakeClock{t: time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// testManager собирает менеджер на временных файлах с поддельными часами,
// поддельным резолвером и поддельными коробками.
func testManager(t *testing.T, clock *fakeClock, box *boxSet, ips map[string][]string) *Manager {
	t.Helper()
	dir := t.TempDir()
	candPath := filepath.Join(dir, "sni_wl_candidates.txt")
	body := "# заголовок\na.ru\nb.ru\nc.ru\nd.ru\ne.ru\n"
	if err := os.WriteFile(candPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Config{
		Enabled:        true,
		CandidatesPath: candPath,
		NetworksPath:   filepath.Join(dir, "sni_wl_nets.txt"),
		NamePath:       filepath.Join(dir, "sni_wl_name.txt"),
		Sweep:          testSweepCfg(box.dialer(t), 10),
		NetCooldown:    24 * time.Hour,
		QueueSize:      4,
		Workers:        1,
		Now:            clock.now,
		Logf:           func(string, ...any) {},
		Resolve: func(ctx context.Context, domain string) ([]string, error) {
			if v, ok := ips[domain]; ok {
				return v, nil
			}
			return nil, errors.New("нет записи")
		},
	}
	m, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return m
}

func TestNewLoadsCandidatesInFileOrder(t *testing.T) {
	m := testManager(t, newClock(), &boxSet{def: cutNever}, nil)
	got := m.Candidates()
	want := []string{"a.ru", "b.ru", "c.ru", "d.ru", "e.ru"}
	if len(got) != len(want) {
		t.Fatalf("кандидатов %d, ждали %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Name != want[i] {
			t.Errorf("кандидат %d = %q, ждали %q", i, got[i].Name, want[i])
		}
	}
}

func TestNewFailsWithoutCandidates(t *testing.T) {
	// Без файла кандидатов подбирать нечего. Отказ должен быть явным — движок
	// его логирует и работает дальше без подсистемы, а не молча делает вид.
	cfg := Defaults()
	cfg.CandidatesPath = filepath.Join(t.TempDir(), "нет-такого.txt")
	if _, err := New(cfg); err == nil {
		t.Fatal("менеджер поднялся без файла кандидатов")
	}
}

func TestOfferDedupsDomainWithinCooldown(t *testing.T) {
	clock := newClock()
	m := testManager(t, clock, &boxSet{def: cutNever}, nil)

	m.Offer("blocked.example", nil)
	m.Offer("blocked.example", nil)
	m.Offer("blocked.example", nil)
	if got := len(m.queue); got != 1 {
		t.Fatalf("в очереди %d наблюдений, ждали 1 — DNS-лог повторяет имя десятки раз в минуту", got)
	}
	if s := m.Stats(); s.Offered != 3 || s.Dropped != 2 {
		t.Errorf("счётчики offered=%d dropped=%d, ждали 3/2", s.Offered, s.Dropped)
	}

	// Через сутки домен снова достоин наблюдения.
	<-m.queue
	clock.advance(24 * time.Hour)
	m.Offer("blocked.example", nil)
	if got := len(m.queue); got != 1 {
		t.Fatalf("после кулдауна в очереди %d, ждали 1", got)
	}
}

func TestOfferDropDoesNotBurnCooldown(t *testing.T) {
	// Та же дисциплина, что уже починена в движке: наблюдение, дропнутое
	// из-за переполнения, НЕ имеет права молчать полные сутки. Иначе первое
	// же посещение сайта сжигает слот, а меряется сеть только назавтра.
	clock := newClock()
	m := testManager(t, clock, &boxSet{def: cutNever}, nil)
	m.cfg.QueueSize = 2
	m.queue = make(chan job, 2)

	m.Offer("one.example", nil)
	m.Offer("two.example", nil)
	m.Offer("three.example", nil) // очередь полна — дроп

	m.mu.Lock()
	_, remembered := m.domains["three.example"]
	m.mu.Unlock()
	if remembered {
		t.Fatal("дропнутый домен занял слот кулдауна на сутки")
	}

	// Освобождаем место — тот же домен должен пройти сразу, без ожидания.
	<-m.queue
	m.Offer("three.example", nil)
	m.mu.Lock()
	_, remembered = m.domains["three.example"]
	m.mu.Unlock()
	if !remembered {
		t.Fatal("после освобождения очереди домен всё ещё не принимается")
	}
}

func TestOfferNeverBlocks(t *testing.T) {
	// Offer зовут из главного цикла демона. Блокировка там означает
	// пропущенные наблюдения DNS у всего дома.
	m := testManager(t, newClock(), &boxSet{def: cutNever}, nil)
	done := make(chan struct{})
	go func() {
		for i := 0; i < 100; i++ {
			m.Offer("d"+string(rune('a'+i%26))+".example", nil)
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Offer заблокировался на переполненной очереди")
	}
}

func TestClaimOnceThenCooldown(t *testing.T) {
	clock := newClock()
	m := testManager(t, clock, &boxSet{def: cutNever}, nil)
	key, _ := NetKeyString("5.9.100.200")

	if !m.claim(key) {
		t.Fatal("первая заявка на незнакомую сеть отклонена")
	}
	if m.claim(key) {
		t.Fatal("сеть отдана дважды — два рабочих мерили бы её одновременно")
	}
	m.release(key)

	// Пока вердикта нет, освобождённую сеть можно взять снова.
	if !m.claim(key) {
		t.Fatal("после release сеть без вердикта не берётся")
	}
	m.mark(key, verdictClean, clock.now())
	m.release(key)

	if m.claim(key) {
		t.Fatal("сеть с вердиктом перемеряется в тот же день")
	}
	clock.advance(23 * time.Hour)
	if m.claim(key) {
		t.Fatal("кулдаун меньше суток")
	}
	clock.advance(2 * time.Hour)
	if !m.claim(key) {
		t.Fatal("через сутки сеть должна быть снова доступна")
	}
}

func TestHandlePublishesNetworkAndName(t *testing.T) {
	clock := newClock()
	box := &boxSet{
		def: cutDetected,
		byName: map[string]int{
			"":     cutNever, // коробка триггерится именем
			"c.ru": cutNever, // пробивает третий кандидат
		},
	}
	m := testManager(t, clock, box, map[string][]string{
		"rutracker.example": {"5.9.100.200"},
	})

	m.handle(context.Background(), job{domain: "rutracker.example"})

	name, err := m.store.LoadName()
	if err != nil {
		t.Fatal(err)
	}
	if name != "c.ru" {
		t.Fatalf("имя %q, ждали c.ru", name)
	}
	nets, err := m.store.LoadNetworks()
	if err != nil {
		t.Fatal(err)
	}
	key, _ := NetKeyString("5.9.100.200")
	if _, ok := nets[key]; !ok || len(nets) != 1 {
		t.Fatalf("в файле сетей %d записей, ждали ровно 5.9.0.0/16", len(nets))
	}
	if v, ok := m.Verdict(key); !ok || v != verdictAffected {
		t.Errorf("вердикт по сети %q (найден=%v), ждали %q", v, ok, verdictAffected)
	}
	if s := m.Stats(); s.Published != 1 || s.Affected != 1 {
		t.Errorf("счётчики published=%d affected=%d", s.Published, s.Affected)
	}

	// Повтор в тот же день не должен ни мерить, ни писать заново.
	before, _ := os.ReadFile(m.store.NetworksPath)
	m.handle(context.Background(), job{domain: "rutracker.example", ips: []string{"5.9.0.1"}})
	after, _ := os.ReadFile(m.store.NetworksPath)
	if string(before) != string(after) {
		t.Error("повторная характеризация той же сети переписала файл")
	}
	if s := m.Stats(); s.Swept != 1 {
		t.Errorf("перебор запускался %d раз, ждали 1", s.Swept)
	}
}

func TestHandleCleanNetworkWritesNothing(t *testing.T) {
	// Сеть не режет — ни файла сетей, ни имени быть не должно. Это и есть
	// «у 99% пользователей конфиг не меняется ни на байт».
	clock := newClock()
	m := testManager(t, clock, &boxSet{def: cutNever}, map[string][]string{
		"ok.example": {"88.198.1.1"},
	})
	m.handle(context.Background(), job{domain: "ok.example"})

	if _, err := os.Stat(m.store.NetworksPath); !os.IsNotExist(err) {
		t.Error("на чистой сети создан файл сетей — профиль соберётся зря")
	}
	if _, err := os.Stat(m.store.NamePath); !os.IsNotExist(err) {
		t.Error("на чистой сети записано имя")
	}
	key, _ := NetKeyString("88.198.1.1")
	if v, _ := m.Verdict(key); v != verdictClean {
		t.Errorf("вердикт %q, ждали %q", v, verdictClean)
	}
}

func TestHandleAffectedWithoutWinnerPublishesNothing(t *testing.T) {
	// Сеть режет, но ни одно имя не пробило. Публиковать её нельзя: профиль
	// подставил бы имя, про которое здесь уже известно, что оно не работает.
	clock := newClock()
	box := &boxSet{def: cutDetected, byName: map[string]int{"": cutDetected}}
	m := testManager(t, clock, box, map[string][]string{
		"hard.example": {"5.9.100.200"},
	})
	m.handle(context.Background(), job{domain: "hard.example"})

	if _, err := os.Stat(m.store.NetworksPath); !os.IsNotExist(err) {
		t.Fatal("сеть без рабочего имени всё-таки опубликована")
	}
	key, _ := NetKeyString("5.9.100.200")
	if v, _ := m.Verdict(key); v != verdictNoName {
		t.Errorf("вердикт %q, ждали %q", v, verdictNoName)
	}
}

func TestHandleUnmeasuredPublishesNothing(t *testing.T) {
	// Контроль не состоялся вовсе: базы для сравнения нет, про сеть не
	// сказано ничего. Ни писать, ни записывать «имени нет» нельзя.
	clock := newClock()
	box := &boxSet{def: cutDead, byName: map[string]int{"example.com": cutDead}}
	m := testManager(t, clock, box, map[string][]string{
		"dead.example": {"5.9.100.200"},
	})
	m.handle(context.Background(), job{domain: "dead.example"})

	if _, err := os.Stat(m.store.NetworksPath); !os.IsNotExist(err) {
		t.Fatal("сеть опубликована по прогону, в котором не состоялся контроль")
	}
	key, _ := NetKeyString("5.9.100.200")
	if v, _ := m.Verdict(key); v != verdictUnmeasured {
		t.Errorf("вердикт %q, ждали %q", v, verdictUnmeasured)
	}
	if s := m.Stats(); s.Unmeasured != 1 {
		t.Errorf("счётчик unmeasured=%d", s.Unmeasured)
	}
	if len(box.called()) != 1 {
		t.Errorf("после несостоявшегося контроля сходили %d раз: %v", len(box.called()), box.called())
	}
}

func TestHandleHandshakeFailuresGiveNoNameNotBan(t *testing.T) {
	// Живой случай: адрес рвёт рукопожатие на КАЖДОМ неподходящем имени, и на
	// плече без SNI тоже. Раньше это объявлялось баном на четвёртой пробе.
	// Теперь это обычный отрицательный ответ, подтверждённый переконтролем.
	clock := newClock()
	box := &boxSet{def: cutDead, byName: map[string]int{"example.com": cutDetected}}
	m := testManager(t, clock, box, map[string][]string{
		"hard.example": {"5.9.100.200"},
	})
	m.handle(context.Background(), job{domain: "hard.example"})

	if _, err := os.Stat(m.store.NetworksPath); !os.IsNotExist(err) {
		t.Fatal("сеть без рабочего имени всё-таки опубликована")
	}
	key, _ := NetKeyString("5.9.100.200")
	if v, _ := m.Verdict(key); v != verdictNoName {
		t.Errorf("вердикт %q, ждали %q", v, verdictNoName)
	}
	// Контроль + плечо без SNI + все пять кандидатов + переконтроль.
	if got := len(box.called()); got != 8 {
		t.Errorf("обращений %d (%v), ждали 8: перебор бросили раньше времени", got, box.called())
	}
}

func TestHandleInconclusiveDoesNotClaimNoName(t *testing.T) {
	// Адрес перестал отвечать по ходу перебора. Отрицательный ответ
	// недостоверен: это отдельный вердикт, а не «имени нет».
	clock := newClock()
	box := &boxSet{def: cutDetected, byName: map[string]int{"example.com": cutDetected}}
	box.onCall = func(b *boxSet, sni string, n int) {
		if n == 1 {
			b.byName["example.com"] = cutDead
		}
	}
	m := testManager(t, clock, box, map[string][]string{
		"flaky.example": {"5.9.100.200"},
	})
	m.handle(context.Background(), job{domain: "flaky.example"})

	if _, err := os.Stat(m.store.NetworksPath); !os.IsNotExist(err) {
		t.Fatal("сеть опубликована по неубедительному прогону")
	}
	key, _ := NetKeyString("5.9.100.200")
	if v, _ := m.Verdict(key); v != verdictInconclusive {
		t.Errorf("вердикт %q, ждали %q", v, verdictInconclusive)
	}
	s := m.Stats()
	if s.Inconclusive != 1 {
		t.Errorf("счётчик inconclusive=%d", s.Inconclusive)
	}
	if s.Affected != 0 {
		t.Errorf("неубедительный прогон посчитан как найденная поражённая сеть (affected=%d)", s.Affected)
	}
}

func TestHandleSkipsPrivateAddresses(t *testing.T) {
	clock := newClock()
	box := &boxSet{def: cutDetected}
	m := testManager(t, clock, box, map[string][]string{
		"lan.example": {"192.168.1.10", "10.0.0.5"},
	})
	m.handle(context.Background(), job{domain: "lan.example"})
	if len(box.called()) != 0 {
		t.Fatalf("сходили в сеть за приватным адресом: %v", box.called())
	}
	if _, err := os.Stat(m.store.NetworksPath); !os.IsNotExist(err) {
		t.Error("приватная сеть попала в файл — фейк полетел бы в локалку")
	}
}

func TestHandleTriesIncumbentNameFirst(t *testing.T) {
	// Действующее имя проверяется первым: одна проба вместо сорока, и это
	// единственная причина, по которой перебор вообще можно позволять себе
	// повторно на домашней линии.
	clock := newClock()
	box := &boxSet{
		def: cutDetected,
		byName: map[string]int{
			"":     cutDetected,
			"e.ru": cutNever,
		},
	}
	m := testManager(t, clock, box, map[string][]string{
		"first.example":  {"5.9.100.200"},
		"second.example": {"88.198.1.1"},
	})
	m.handle(context.Background(), job{domain: "first.example"})
	if got, _ := m.store.LoadName(); got != "e.ru" {
		t.Fatalf("имя %q, ждали e.ru", got)
	}

	box.mu.Lock()
	box.calls = nil
	box.mu.Unlock()

	m.handle(context.Background(), job{domain: "second.example"})
	calls := box.called()
	// example.com (контроль), "" (без SNI) и ОДИН батч из четырёх, в котором
	// уже есть действующее имя. Порядок внутри батча недетерминирован — он
	// идёт параллельно, — поэтому проверяем состав и размер: без подъёма
	// действующего имени e.ru (последняя строка файла) попало бы во второй
	// батч, и обращений было бы 7, а не 6.
	if len(calls) != 6 {
		t.Fatalf("обращений %d (%v), ждали 6: контроль + без SNI + один батч", len(calls), calls)
	}
	found := false
	for _, c := range calls[2:] {
		if c == "e.ru" {
			found = true
		}
	}
	if !found {
		t.Fatalf("действующее имя не попало в первый батч: %v", calls)
	}
	nets, _ := m.store.LoadNetworks()
	if len(nets) != 2 {
		t.Errorf("в файле %d сетей, ждали 2", len(nets))
	}
}

func TestHandleSwitchesNameWhenIncumbentStopsWorking(t *testing.T) {
	clock := newClock()
	box := &boxSet{
		def: cutDetected,
		byName: map[string]int{
			"":     cutDetected,
			"a.ru": cutNever,
		},
	}
	m := testManager(t, clock, box, map[string][]string{"one.example": {"5.9.100.200"}})
	m.handle(context.Background(), job{domain: "one.example"})
	if got, _ := m.store.LoadName(); got != "a.ru" {
		t.Fatalf("имя %q, ждали a.ru", got)
	}

	// Вторая сеть: прежнее имя там не проходит, проходит другое.
	box.mu.Lock()
	box.byName["a.ru"] = cutDetected
	box.byName["d.ru"] = cutNever
	box.mu.Unlock()

	m.handle(context.Background(), job{domain: "two.example", ips: []string{"88.198.1.1"}})
	if got, _ := m.store.LoadName(); got != "d.ru" {
		t.Fatalf("имя %q, ждали смены на d.ru", got)
	}
	nets, _ := m.store.LoadNetworks()
	if len(nets) != 2 {
		t.Errorf("в файле %d сетей, ждали 2", len(nets))
	}
}

func TestNewRestoresKnownNetworksWithoutRestartStorm(t *testing.T) {
	// Известные сети получают отметку времени СТАРТА, а не нулевую. Иначе
	// каждый перезапуск демона (обновление, OOM-сторож) начинал бы
	// перепроверку всех опубликованных сетей разом.
	clock := newClock()
	box := &boxSet{def: cutDetected, byName: map[string]int{"": cutNever, "a.ru": cutNever}}
	m := testManager(t, clock, box, map[string][]string{"one.example": {"5.9.100.200"}})
	m.handle(context.Background(), job{domain: "one.example"})

	m2, err := New(Config{
		Enabled:        true,
		CandidatesPath: m.cfg.CandidatesPath,
		NetworksPath:   m.store.NetworksPath,
		NamePath:       m.store.NamePath,
		Sweep:          m.cfg.Sweep,
		NetCooldown:    24 * time.Hour,
		Now:            clock.now,
		Logf:           func(string, ...any) {},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	key, _ := NetKeyString("5.9.100.200")
	if m2.claim(key) {
		t.Fatal("после перезапуска известная сеть сразу же перемеряется")
	}
	if s := m2.Stats(); s.Networks != 1 || s.Name != "a.ru" {
		t.Errorf("после перезапуска networks=%d name=%q", s.Networks, s.Name)
	}
	clock.advance(25 * time.Hour)
	if !m2.claim(key) {
		t.Error("через сутки после перезапуска сеть должна перемеряться")
	}
}

func TestEvictDropsOnlyExpiredDomains(t *testing.T) {
	clock := newClock()
	m := testManager(t, clock, &boxSet{def: cutNever}, nil)
	m.Offer("old.example", nil)
	<-m.queue
	clock.advance(25 * time.Hour)
	m.Offer("fresh.example", nil)

	if n := m.evict(); n != 1 {
		t.Fatalf("выметено %d записей, ждали 1", n)
	}
	m.mu.Lock()
	_, oldLeft := m.domains["old.example"]
	_, freshLeft := m.domains["fresh.example"]
	m.mu.Unlock()
	if oldLeft {
		t.Error("протухшая запись осталась")
	}
	if !freshLeft {
		t.Error("свежая запись выметена")
	}
}

func TestRunStopsOnContextCancel(t *testing.T) {
	m := testManager(t, newClock(), &boxSet{def: cutNever}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("Run не вернулся после отмены контекста")
	}
}

func TestProvenanceIsSingleLine(t *testing.T) {
	got := provenance("сеть 5.9.0.0/16\nимя a.ru")
	if strings.Count(got, "\n") != 0 {
		t.Errorf("провенанс в несколько строк: %q", got)
	}
	if !strings.HasPrefix(got, provenancePrefix) {
		t.Errorf("нет метки происхождения: %q", got)
	}
}
