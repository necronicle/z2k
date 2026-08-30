package sniwl

import (
	"context"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"
)

// boxSet — стенд из поддельных коробок, разных для разных имён. Ровно это и
// меряет перебор: одно и то же соединение к одному адресу ведёт себя иначе в
// зависимости от имени в ClientHello.
type boxSet struct {
	mu sync.Mutex
	// byName — порог обрыва для конкретного имени; отсутствующее имя
	// получает def.
	byName map[string]int
	def    int
	calls  []string
	// onCall — рука теста, которой стенд меняют ПО ХОДУ прогона. Вызывается
	// под замком уже ПОСЛЕ того, как решение по текущей пробе принято,
	// поэтому мутация действует со следующего обращения. Так моделируется
	// адрес, который перестал нас обслуживать в середине перебора: без этого
	// «контроль деградировал» не проверить вовсе.
	onCall func(b *boxSet, sni string, n int)
}

func (b *boxSet) dialer(t *testing.T) Dialer {
	t.Helper()
	return func(ctx context.Context, addr, sni string) (net.Conn, error) {
		b.mu.Lock()
		cut, ok := b.byName[sni]
		if !ok {
			cut = b.def
		}
		b.calls = append(b.calls, sni)
		if b.onCall != nil {
			b.onCall(b, sni, len(b.calls))
		}
		b.mu.Unlock()
		client, server := net.Pipe()
		go (&fakeBox{cutAt: cut}).serve(server)
		t.Cleanup(func() { _ = client.Close() })
		return client, nil
	}
}

func (b *boxSet) called() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.calls...)
}

const (
	cutNever    = 1 << 30 // имя пробивает: все куски проходят
	cutDetected = 4000    // обрыв внутри детект-окна
	cutDead     = 0       // адрес нас режет с нулевого куска
)

func testSweepCfg(d Dialer, maxCand int) SweepConfig {
	return SweepConfig{
		BaselineSNI:   "example.com",
		MaxCandidates: maxCand,
		Concurrency:   4,
		// Отрицательное значение = без паузы. Боевая секунда между батчами
		// превратила бы каждый тест перебора в минуту ожидания; сама пауза
		// проверяется отдельно, в TestSweepPausesBetweenBatches.
		BatchPause: -1,
		Probe:      testProbeCfg(d),
	}
}

// manyCands — список из n имён, где номер имени равен его номеру строки.
func manyCands(n int) []Candidate {
	out := make([]Candidate, n)
	for i := range out {
		out[i] = Candidate{Name: fmt.Sprintf("c%03d.ru", i+1), Line: i + 1}
	}
	return out
}

func cands(names ...string) []Candidate {
	out := make([]Candidate, len(names))
	for i, n := range names {
		out[i] = Candidate{Name: n, Line: i + 1}
	}
	return out
}

func TestSweepReportsDuration(t *testing.T) {
	// Длительность проставляет отложенная функция. При возврате по значению
	// она писала бы в уже скопированную структуру, и в JSON вечно висел бы
	// "took": 0 — ровно это и было в первой версии.
	box := &boxSet{def: cutNever}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru"), testSweepCfg(box.dialer(t), 10))
	if res.Took <= 0 {
		t.Fatalf("Took=%v — длительность не доехала до вызывающего", res.Took)
	}
	if res.Baseline.DurationMS < 0 {
		t.Errorf("DurationMS=%d", res.Baseline.DurationMS)
	}
}

func TestSweepStopsOnCleanNetwork(t *testing.T) {
	// Контроль прошёл целиком — сеть поток не режет. Перебор не запускается
	// вовсе: без контроля, давшего DETECTED, сравнивать не с чем, и любой
	// «победитель» был бы победой над пустотой.
	box := &boxSet{def: cutNever}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru"), testSweepCfg(box.dialer(t), 10))
	if res.Affected {
		t.Fatalf("сеть объявлена поражённой: %s", res.Reason)
	}
	if res.Tried != 0 {
		t.Errorf("сделано %d проб кандидатов на чистой сети", res.Tried)
	}
	if res.State != StateClean {
		t.Errorf("состояние %s, ждали %s", res.State, StateClean)
	}
	if got := box.called(); len(got) != 1 || got[0] != "example.com" {
		t.Errorf("сходили к %v, ждали только контроль", got)
	}
}

func TestSweepStopsWhenBaselineBreaksEarly(t *testing.T) {
	// Контроль оборвался раньше детект-окна — это шум линии. Объявлять по
	// нему поражение значит публиковать сеть по чиху канала.
	box := &boxSet{def: 1000}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru"), testSweepCfg(box.dialer(t), 10))
	if res.Affected || res.State != StateNoise {
		t.Fatalf("состояние %s (режет=%v), ждали %s: %s", res.State, res.Affected, StateNoise, res.Reason)
	}
	if res.Tried != 0 {
		t.Errorf("сделано %d проб после шумного контроля", res.Tried)
	}
}

func TestSweepRunsCandidatesEvenWhenNoSNIArmFails(t *testing.T) {
	// Плечо без SNI не состоялось — раньше это считалось баном и бросало
	// перебор. Это тот же выдуманный сигнал: ClientHello вообще без
	// расширения SNI для коробки ровно так же «не из белого списка», как и
	// чужое имя, и рукопожатие она рвёт по той же причине. Бросать здесь
	// значит не начать перебор именно там, где он и нужен.
	box := &boxSet{
		def: cutDead,
		byName: map[string]int{
			"example.com": cutDetected,
			"c.ru":        cutNever,
		},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru"), testSweepCfg(box.dialer(t), 10))
	if res.NoSNI.Status != StatusFail {
		t.Fatalf("плечо без SNI дало %s — стенд собран не про то", res.NoSNI.Status)
	}
	if res.State != StateFound || res.Winner != "c.ru" {
		t.Fatalf("состояние %s, победитель %q — перебор бросили из-за плеча без SNI: %s",
			res.State, res.Winner, res.Reason)
	}
	if !res.Affected {
		t.Error("контроль дал DETECTED — сеть всё равно поражена")
	}
}

func TestSweepFailingCandidateDoesNotStopSweep(t *testing.T) {
	// ЗАМЕР НА ЛИНИИ, 213.133.116.44: hcaptcha.com, vk.com, 2gis.com, 2gis.ru —
	// code=000, 0 байт, 12 с таймаута; disk.rzd.ru — code=403 за 0.26 с. Первые
	// четыре имени файла кандидатов — ровно эти, то есть первый батч
	// проваливается ЦЕЛИКОМ у всех, кому профиль нужен. Правило «весь батч
	// провалился = бан» убивало перебор на 4-й пробе из 188.
	box := &boxSet{
		def: cutDead,
		byName: map[string]int{
			"example.com": cutDetected,
			"":            cutDetected,
			"h.ru":        cutNever,
		},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru", "d.ru", "e.ru", "f.ru", "g.ru", "h.ru"),
		testSweepCfg(box.dialer(t), 10))
	if res.State != StateFound {
		t.Fatalf("состояние %s, ждали %s: %s", res.State, StateFound, res.Reason)
	}
	if res.Winner != "h.ru" {
		t.Fatalf("победитель %q, ждали h.ru — перебор бросили на провалившемся батче", res.Winner)
	}
	if res.Tried != 8 {
		t.Errorf("сделано %d проб, ждали все 8", res.Tried)
	}
}

func TestSweepFindsWinnerBeyondFirstBatch(t *testing.T) {
	// Ровно поле: единственное имя, про которое ЗАМЕРЕНО, что оно работает
	// (disk.rzd.ru), стоит 57-м в файле кандидатов. Всё до него рвёт
	// рукопожатие. Перебор обязан дойти.
	list := manyCands(60)
	winner := list[56] // 57-й по порядку файла
	box := &boxSet{
		def: cutDead,
		byName: map[string]int{
			"example.com": cutDetected,
			"":            cutDead,
			winner.Name:   cutNever,
		},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443", list, testSweepCfg(box.dialer(t), 200))
	if res.State != StateFound {
		t.Fatalf("состояние %s, ждали %s: %s", res.State, StateFound, res.Reason)
	}
	if res.Winner != winner.Name || res.WinnerLine != 57 {
		t.Fatalf("победитель %q (строка %d), ждали %q (строка 57)",
			res.Winner, res.WinnerLine, winner.Name)
	}
	// 57-й лежит в 15-м батче по четыре, то есть спрошены все 60.
	if res.Tried != 60 {
		t.Errorf("сделано %d проб, ждали 60", res.Tried)
	}
}

func TestSweepDefaultCapCoversWholeShippedList(t *testing.T) {
	// Потолок 40 отрезал список ровно там, где живёт единственное проверенное
	// имя (57-е). Умолчание обязано покрывать весь отгружаемый файл — 188 имён
	// плюс поднятое вперёд действующее.
	got := SweepConfig{}.WithDefaults().MaxCandidates
	if got < 189 {
		t.Fatalf("потолок кандидатов по умолчанию %d — файл из 188 имён не проходит целиком", got)
	}
}

func TestSweepDetectsNoSNIWorks(t *testing.T) {
	// Плечо совсем без расширения SNI проходит — значит коробка триггерится
	// ИМЕНЕМ, и подстановка имени вообще имеет смысл.
	box := &boxSet{
		def: cutDetected,
		byName: map[string]int{
			"":     cutNever,
			"c.ru": cutNever,
		},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru"), testSweepCfg(box.dialer(t), 10))
	if !res.NoSNIWorks {
		t.Fatalf("плечо без SNI прошло, а флага нет: %s", res.Reason)
	}
	if res.Winner != "c.ru" {
		t.Errorf("победитель %q, ждали c.ru", res.Winner)
	}
}

func TestSweepPicksFirstWinnerInFileOrder(t *testing.T) {
	// В одном батче проходят и b.ru, и d.ru. Победителем обязан стать b.ru:
	// порядок файла и есть приоритет, а не «кто первым ответил».
	box := &boxSet{
		def: cutDetected,
		byName: map[string]int{
			"b.ru": cutNever,
			"d.ru": cutNever,
		},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru", "d.ru", "e.ru"), testSweepCfg(box.dialer(t), 10))
	if res.Winner != "b.ru" {
		t.Fatalf("победитель %q, ждали b.ru (%s)", res.Winner, res.Reason)
	}
	if res.WinnerLine != 2 {
		t.Errorf("строка победителя %d, ждали 2", res.WinnerLine)
	}
	if res.Tried != 4 {
		t.Errorf("сделано %d проб, ждали один батч из 4", res.Tried)
	}
	if !res.Affected {
		t.Error("сеть не помечена поражённой")
	}
}

func TestSweepStopsAtFirstWinningBatch(t *testing.T) {
	// Победитель в первом батче — второй батч не должен запускаться вовсе.
	box := &boxSet{
		def:    cutDetected,
		byName: map[string]int{"a.ru": cutNever},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru", "d.ru", "e.ru", "f.ru"), testSweepCfg(box.dialer(t), 10))
	if res.Winner != "a.ru" || res.Tried != 4 {
		t.Fatalf("победитель %q после %d проб, ждали a.ru после 4", res.Winner, res.Tried)
	}
}

func TestSweepReportsNoWinnerWhenControlReproduces(t *testing.T) {
	// Список исчерпан, победителя нет, переконтроль дал то же самое, что и
	// контроль в начале. Только в этом случае «имени нет» — ответ, а не
	// догадка.
	box := &boxSet{def: cutDetected}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru"), testSweepCfg(box.dialer(t), 10))
	if res.Winner != "" {
		t.Fatalf("нашёлся победитель %q там, где режется всё", res.Winner)
	}
	if res.State != StateNoName {
		t.Fatalf("состояние %s, ждали %s: %s", res.State, StateNoName, res.Reason)
	}
	if res.Recheck.Status != StatusDetected {
		t.Errorf("переконтроль %s, ждали %s — иначе сравнивать не с чем",
			res.Recheck.Status, StatusDetected)
	}
	if !res.Affected {
		t.Error("сеть режет, а флага нет")
	}
	if res.Tried != 3 {
		t.Errorf("сделано %d проб, ждали 3", res.Tried)
	}
}

func TestSweepDegradedControlIsInconclusiveNotNoName(t *testing.T) {
	// Адрес перестал нас обслуживать ПО ХОДУ перебора: в начале контроль
	// отвечал, в конце — нет. Значит последние пробы были не про имена, и
	// «имя не найдено» здесь было бы выдуманной уверенностью. Тот же приём и
	// та же причина, что у classify.VerdictInconclusive.
	box := &boxSet{
		def:    cutDetected,
		byName: map[string]int{"example.com": cutDetected},
	}
	box.onCall = func(b *boxSet, sni string, n int) {
		// Контроль уже сделан — дальше адрес молчит на всём.
		if n == 1 {
			b.byName["example.com"] = cutDead
		}
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru"), testSweepCfg(box.dialer(t), 10))
	if res.State != StateInconclusive {
		t.Fatalf("состояние %s, ждали %s: %s", res.State, StateInconclusive, res.Reason)
	}
	if res.Baseline.Status != StatusDetected {
		t.Errorf("исходный контроль %s — стенд собран не про то", res.Baseline.Status)
	}
	if res.Recheck.Status != StatusFail {
		t.Errorf("переконтроль %s, ждали %s", res.Recheck.Status, StatusFail)
	}
	if res.Winner != "" {
		t.Errorf("на неубедительном прогоне назначен победитель %q", res.Winner)
	}
	if res.Tried != 3 {
		t.Errorf("сделано %d проб, ждали 3 — перебор обязан пройти список целиком", res.Tried)
	}
}

func TestSweepPausesBetweenBatches(t *testing.T) {
	// Детектора бана больше нет, и единственное, что стоит между нами и
	// самостоятельно заработанным рейт-лимитом, — пауза между батчами.
	const pause = 120 * time.Millisecond
	run := func(p time.Duration) time.Duration {
		box := &boxSet{
			def:    cutDead,
			byName: map[string]int{"example.com": cutDetected},
		}
		cfg := testSweepCfg(box.dialer(t), 200)
		cfg.BatchPause = p
		res := RunSweep(context.Background(), "1.2.3.4:443", manyCands(12), cfg)
		if res.Tried != 12 {
			t.Fatalf("сделано %d проб, ждали 12", res.Tried)
		}
		return res.Took
	}
	fast := run(-1)    // без паузы
	slow := run(pause) // три батча = две паузы
	if slow-fast < 2*pause-pause/2 {
		t.Fatalf("с паузой %v прогон занял %v против %v без неё — паузы между батчами нет",
			pause, slow, fast)
	}
}

func TestSweepBatchPauseDefaultIsSane(t *testing.T) {
	cfg := SweepConfig{}.WithDefaults()
	if cfg.BatchPause != DefaultBatchPause || cfg.BatchPause <= 0 {
		t.Fatalf("пауза между батчами по умолчанию %v", cfg.BatchPause)
	}
	// Отрицательное значение — единственный способ выключить паузу совсем.
	off := SweepConfig{BatchPause: -1}.WithDefaults()
	if off.BatchPause != 0 {
		t.Fatalf("BatchPause=-1 дал %v, ждали ноль", off.BatchPause)
	}
}

func TestSweepHonoursCandidateCap(t *testing.T) {
	// Потолок за прогон — единственное, что стоит между нами и 7 МБ
	// аплинка на домашней линии.
	box := &boxSet{def: cutDetected}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru", "d.ru", "e.ru", "f.ru", "g.ru", "h.ru"),
		testSweepCfg(box.dialer(t), 4))
	if res.Tried != 4 {
		t.Fatalf("сделано %d проб при потолке 4", res.Tried)
	}
}

func TestSweepWholeBatchFailIsNotABan(t *testing.T) {
	// Весь батч провалился, но контроль в конце воспроизводится — значит
	// адрес нас обслуживает, просто ни одно из спрошенных имён не в белом
	// списке. Это достоверный минус, а не бан.
	box := &boxSet{
		def: cutDead,
		byName: map[string]int{
			"example.com": cutDetected,
			"":            cutDetected,
		},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru", "d.ru", "e.ru", "f.ru", "g.ru", "h.ru"),
		testSweepCfg(box.dialer(t), 10))
	if res.State != StateNoName {
		t.Fatalf("состояние %s, ждали %s: %s", res.State, StateNoName, res.Reason)
	}
	if res.Tried != 8 {
		t.Errorf("сделано %d проб, ждали все 8 — перебор бросили на первом батче", res.Tried)
	}
	if res.Winner != "" {
		t.Errorf("назначен победитель %q там, где не прошло ничего", res.Winner)
	}
}

func TestSweepSingleFailInBatchDoesNotStopSweep(t *testing.T) {
	// Один провал из четырёх — обычный отрицательный ответ. Прерывать перебор
	// нельзя: следующий батч может содержать рабочее имя.
	box := &boxSet{
		def: cutDetected,
		byName: map[string]int{
			"a.ru": cutDead,
			"f.ru": cutNever,
		},
	}
	res := RunSweep(context.Background(), "1.2.3.4:443",
		cands("a.ru", "b.ru", "c.ru", "d.ru", "e.ru", "f.ru"), testSweepCfg(box.dialer(t), 10))
	if res.State != StateFound {
		t.Fatalf("состояние %s, ждали %s: %s", res.State, StateFound, res.Reason)
	}
	if res.Winner != "f.ru" {
		t.Errorf("победитель %q, ждали f.ru", res.Winner)
	}
}

func TestSweepCancelledContext(t *testing.T) {
	box := &boxSet{def: cutDetected}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res := RunSweep(ctx, "1.2.3.4:443", cands("a.ru"), testSweepCfg(box.dialer(t), 10))
	if res.Winner != "" {
		t.Errorf("на отменённом контексте назначен победитель %q", res.Winner)
	}
	if res.State == StateFound || res.State == StateNoName {
		t.Errorf("состояние %s: отмена выдана за измерение", res.State)
	}
	if res.Took > 5*time.Second {
		t.Errorf("отмена не остановила перебор: %v", res.Took)
	}
}
