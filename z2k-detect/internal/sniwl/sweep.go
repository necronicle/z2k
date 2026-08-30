package sniwl

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// Умолчания перебора. Оригинал гонит 50 проб одновременно, все AS сразу и
// ищет по три имени на сеть — витрина для человека за десктопом. У нас 2 ядра,
// 500 МБ и домашний аплинк, поэтому:
const (
	// DefaultSweepConcurrency — одновременных проб внутри одной сети.
	// 50 живых TLS-сессий на один внешний адрес — это и нагрузка на роутер,
	// и верный способ поймать рейт-лимит цели.
	DefaultSweepConcurrency = 4
	// DefaultMaxCandidates — потолок имён за прогон.
	//
	// Был 40 «ради аплинка», и резал список ровно там, где живёт
	// единственное имя, про которое на линии владельца ЗАМЕРЕНО, что оно
	// работает: disk.rzd.ru — 57-й кандидат файла (строка 74). С потолком 40
	// подбор не нашёл бы его никогда, а хвост из 148 отгружаемых имён был бы
	// украшением. 200 покрывает весь файл (188 имён) с запасом на поднятое
	// вперёд действующее имя.
	//
	// Цена хвоста — время, а не байты: имя вне белого списка коробка рубит
	// на РУКОПОЖАТИИ (замер на 213.133.116.44: hcaptcha.com / vk.com /
	// 2gis.com / 2gis.ru — code=000, 0 байт, 12.00 с таймаута), то есть
	// аплинка такой кандидат не тратит вовсе. Частоту ограничивает кулдаун
	// в сутки на сеть, а находка обрывает перебор на первом же прошедшем.
	DefaultMaxCandidates = 200
	// DefaultBatchPause — пауза МЕЖДУ батчами.
	//
	// Детектора бана здесь больше нет (см. RunSweep): отличить «имя не в
	// белом списке» от «нас режут» по провалу пробы на этой коробке нельзя.
	// Значит единственное, что стоит между нами и самостоятельно
	// заработанным рейт-лимитом, — не гнать сотню соединений подряд.
	// Секунда на батч из четырёх — это 4 соединения в секунду к одному
	// адресу.
	DefaultBatchPause = time.Second
)

// SweepState — исход прогона по ОДНОЙ сети.
//
// Отдельный тип, а не набор булей: состояния взаимоисключающие, и
// «неубедительно» обязано быть видно как самостоятельный ответ, а не как
// отсутствие победителя. Тот же приём и по той же причине применён в
// internal/classify (VerdictInconclusive): выдавать догадку за вердикт хуже,
// чем честно сказать «померить не вышло».
type SweepState string

const (
	// StateClean — контроль прошёл все куски: сеть поток не режет.
	StateClean SweepState = "clean"
	// StateNoise — контроль оборвался раньше детект-окна. Шум линии, не коробка.
	StateNoise SweepState = "noise"
	// StateUnmeasured — контроль не состоялся вовсе: соединения нет, базы для
	// сравнения нет. Про сеть не сказано НИЧЕГО.
	StateUnmeasured SweepState = "unmeasured"
	// StateFound — имя найдено. Единственное состояние, по которому что-то
	// публикуется.
	StateFound SweepState = "found"
	// StateNoName — список исчерпан, победителя нет, И контрольная проба
	// ПОСЛЕ перебора воспроизвела исходную. Отрицательный ответ достоверен.
	StateNoName SweepState = "no_name"
	// StateInconclusive — список исчерпан, победителя нет, но контроль по
	// ходу перебора деградировал: адрес перестал отвечать так же, как в
	// начале. Отрицательный ответ НЕ достоверен, сеть надо мерить позже.
	StateInconclusive SweepState = "inconclusive"
	// StateCancelled — прогон оборвал контекст (демон гасят). Это про нас, а
	// не про сеть: вердикта нет.
	StateCancelled SweepState = "cancelled"
)

// SweepConfig — ручки перебора имён по ОДНОЙ сети.
type SweepConfig struct {
	// BaselineSNI — нейтральное имя контрольного плеча.
	BaselineSNI string
	// MaxCandidates — сколько имён максимум пробуем за прогон.
	MaxCandidates int
	// Concurrency — одновременных проб. Размер батча равен ему же: батч,
	// который ждёт больше, чем может выполнить, только тянет время.
	Concurrency int
	// BatchPause — пауза между батчами. Ноль означает умолчание,
	// ОТРИЦАТЕЛЬНОЕ значение — «без паузы» (так её выключают тесты).
	BatchPause time.Duration
	Probe      ProbeConfig
}

// WithDefaults возвращает копию с заполненными умолчаниями.
func (c SweepConfig) WithDefaults() SweepConfig {
	if c.BaselineSNI == "" {
		c.BaselineSNI = DefaultBaselineSNI
	}
	if c.MaxCandidates <= 0 {
		c.MaxCandidates = DefaultMaxCandidates
	}
	if c.Concurrency <= 0 {
		c.Concurrency = DefaultSweepConcurrency
	}
	if c.BatchPause == 0 {
		c.BatchPause = DefaultBatchPause
	}
	if c.BatchPause < 0 {
		c.BatchPause = 0
	}
	c.Probe = c.Probe.WithDefaults()
	return c
}

// SweepResult — что перебор узнал про одну сеть.
type SweepResult struct {
	Addr    string `json:"addr"`
	Network string `json:"network"`
	// State — исход прогона. Единственное поле, по которому принимают
	// решение вызывающие; остальные — доказательства к нему.
	State SweepState `json:"state"`
	// Affected — сеть режет поток по объёму. Только при true имеет смысл
	// вообще искать имя и тем более что-то публиковать.
	Affected bool `json:"affected"`
	// NoSNIWorks — плечо вообще без расширения SNI проходит. Значит коробка
	// триггерится ИМЕНЕМ, и подстановка имени — правильный рычаг.
	NoSNIWorks bool        `json:"no_sni_works"`
	Baseline   ProbeResult `json:"baseline"`
	NoSNI      ProbeResult `json:"no_sni"`
	// Recheck — контроль, повторённый ПОСЛЕ исчерпания списка. Заполняется
	// только когда победителя не нашлось: он и отделяет достоверное
	// «имени нет» от «адрес перестал нас обслуживать по дороге».
	Recheck ProbeResult `json:"recheck"`
	// Winner — имя-победитель, первое прошедшее в порядке файла.
	Winner     string `json:"winner,omitempty"`
	WinnerLine int    `json:"winner_line,omitempty"`
	// Tried — сколько имён реально спросили.
	Tried  int           `json:"tried"`
	Reason string        `json:"reason"`
	Took   time.Duration `json:"took"`
}

// RunSweep характеризует одну сеть и подбирает для неё имя.
//
// Порядок шагов не произвольный:
//
//  1. КОНТРОЛЬ нейтральным именем. Без него весь перебор бессмыслен: не с чем
//     сравнивать. Контроль обязан дать DETECTED — иначе сеть не наша, и
//     публиковать её нельзя ни при каком результате перебора.
//  2. Плечо БЕЗ SNI. Это ИЗМЕРЕНИЕ гипотезы «триггерится именем», и только
//     оно. Гейтом перебора оно не является — см. ниже.
//  3. Батчи кандидатов в порядке файла, с паузой между батчами. Победитель —
//     ПЕРВЫЙ прошедший; ранжирования по скорости нет, потому что порядок
//     файла и есть приоритет.
//  4. Список исчерпан без победителя — ПОВТОРНЫЙ контроль. Он и решает,
//     достоверен ли отрицательный ответ.
//
// # ПОЧЕМУ ЗДЕСЬ НЕТ ДЕТЕКТОРА БАНА
//
// Был: «весь батч провалился — значит нас забанили, перебор бросаем». Это
// неверно, и это измерено на живой линии. На этой коробке имя, которого нет
// в белом списке, рвёт САМО РУКОПОЖАТИЕ, а не режет объём. Замер curl на
// 213.133.116.44: hcaptcha.com, vk.com, 2gis.com, 2gis.ru — code=000, 0 байт,
// 12.00 с таймаута каждый; disk.rzd.ru на том же адресе — code=403, 5015
// байт, 0.26 с. Первые четыре — ровно первые четыре строки файла кандидатов,
// то есть ПЕРВЫЙ БАТЧ проваливается целиком у всех, кому этот профиль вообще
// нужен. Живой прогон это и показал: «имя не найдено, проб сделано 4 за
// 17.463s; бан/рейт-лимит после 4 проб» — перебор умер на 4-м кандидате из
// 188, не дойдя до 57-го, который работает. Адрес при этом забанен НЕ БЫЛ:
// сразу после прогона он шесть раз подряд ответил за 0.26 с.
//
// Значит StatusFail у кандидата — это НОРМАЛЬНЫЙ ОТРИЦАТЕЛЬНЫЙ ОТВЕТ. Отличить
// по нему «имя не в белом списке» от «нас режут» нельзя ничем, поэтому сигнала
// «бан» здесь нет вовсе: выдумывать его — значит снова получить прогон,
// который умирает на четвёртой пробе. Вместо угадывания — калиброванный отказ
// в конце (шаг 4) и пауза между батчами, чтобы не выбить себя рейт-лимитом
// самим.
//
// Возврат именованный: длительность проставляет отложенная функция, а при
// возврате по значению она писала бы в уже скопированную структуру, и Took
// всегда оставался бы нулём. Тот же приём и по той же причине стоит в
// classify.TransferProbe.
func RunSweep(ctx context.Context, addr string, cands []Candidate, cfg SweepConfig) (res SweepResult) {
	cfg = cfg.WithDefaults()
	start := time.Now()
	res = SweepResult{Addr: addr}
	defer func() { res.Took = time.Since(start) }()

	// 1. Контроль.
	res.Baseline = Probe(ctx, addr, cfg.BaselineSNI, cfg.Probe, 0)
	switch res.Baseline.Status {
	case StatusFail:
		res.State = StateUnmeasured
		res.Reason = "контроль не состоялся: " + res.Baseline.Detail +
			" — базы для сравнения нет, про сеть не сказано ничего"
		return res
	case StatusOK:
		res.State = StateClean
		res.Reason = fmt.Sprintf("контроль (%s) прошёл все %d кусков — сеть поток не режет",
			cfg.BaselineSNI, cfg.Probe.Chunks)
		return res
	case StatusBreak:
		res.State = StateNoise
		res.Reason = "контроль оборвался раньше детект-окна: " + res.Baseline.Detail +
			" — это шум линии, а не коробка"
		return res
	}
	res.Affected = true
	res.Reason = fmt.Sprintf("контроль (%s) оборван на %d байт аплинка",
		cfg.BaselineSNI, res.Baseline.UplinkBytes)
	hint := res.Baseline.RTT

	// 2. Плечо без SNI — ИЗМЕРЕНИЕ, а не гейт.
	//
	// Раньше его провал бросал перебор как «адрес нас режет». Это тот же
	// выдуманный сигнал: ClientHello без расширения SNI для коробки ровно так
	// же «не из белого списка», как и чужое имя, и рукопожатие она рвёт по
	// той же причине. Бросать здесь значит не начать перебор именно там, где
	// он нужен.
	res.NoSNI = Probe(ctx, addr, "", cfg.Probe, hint)
	switch res.NoSNI.Status {
	case StatusOK:
		res.NoSNIWorks = true
		res.Reason += "; без расширения SNI поток проходит — коробка триггерится ИМЕНЕМ"
	case StatusFail:
		res.Reason += "; плечо без SNI не состоялось (" + res.NoSNI.Detail +
			") — на этой коробке рукопожатие рвётся и от неподходящего имени, перебор это не отменяет"
	}

	// 3. Батчи.
	if len(cands) > cfg.MaxCandidates {
		cands = cands[:cfg.MaxCandidates]
	}
	for from := 0; from < len(cands); from += cfg.Concurrency {
		if err := ctx.Err(); err != nil {
			res.State = StateCancelled
			res.Reason += "; перебор прерван: " + err.Error()
			return res
		}
		if from > 0 && !waitBetween(ctx, cfg.BatchPause) {
			res.State = StateCancelled
			res.Reason += "; перебор прерван на паузе между батчами: " + ctx.Err().Error()
			return res
		}
		to := from + cfg.Concurrency
		if to > len(cands) {
			to = len(cands)
		}
		batch := cands[from:to]
		out := probeBatch(ctx, addr, batch, cfg, hint)
		res.Tried += len(batch)

		// Провалы батча НЕ считаются и НЕ прерывают перебор: StatusFail у
		// кандидата — обычный отрицательный ответ, см. шапку функции.
		//
		// Победитель — первый по порядку файла, не первый по времени.
		for i, r := range out {
			if r.Status == StatusOK {
				res.State = StateFound
				res.Winner = batch[i].Name
				res.WinnerLine = batch[i].Line
				res.Reason += fmt.Sprintf("; имя найдено: %s (строка %d, проба %d)",
					res.Winner, res.WinnerLine, from+i+1)
				return res
			}
		}
	}

	// 4. Калиброванный отказ.
	return recheckAfterSweep(ctx, addr, cfg, hint, res)
}

// recheckAfterSweep повторяет контрольную пробу после исчерпания списка и
// решает, чего стоит отрицательный ответ.
//
// Смысл ровно один: отличить «мы спросили все имена, и ни одно не подошло» от
// «адрес по ходу перебора перестал нас обслуживать, и последние сорок ответов
// были не про имена». Первое — достоверный минус, по нему сеть помечается и
// не трогается сутки. Второе — «неубедительно»: мерить надо заново.
func recheckAfterSweep(ctx context.Context, addr string, cfg SweepConfig, hint time.Duration, res SweepResult) SweepResult {
	if err := ctx.Err(); err != nil {
		res.State = StateCancelled
		res.Reason += "; перебор прерван перед переконтролем: " + err.Error()
		return res
	}
	res.Recheck = Probe(ctx, addr, cfg.BaselineSNI, cfg.Probe, hint)
	if res.Recheck.Status == res.Baseline.Status {
		res.State = StateNoName
		res.Reason += fmt.Sprintf("; имя не найдено за %d проб, переконтроль (%s) воспроизвёл исходный %s"+
			" — отрицательный ответ достоверен",
			res.Tried, cfg.BaselineSNI, res.Baseline.Status)
		return res
	}
	res.State = StateInconclusive
	res.Reason += fmt.Sprintf("; имя не найдено за %d проб, НО переконтроль (%s) дал %s вместо %s (%s)"+
		" — адрес перестал отвечать так же, как в начале; отрицательный ответ недостоверен, мерить заново позже",
		res.Tried, cfg.BaselineSNI, res.Recheck.Status, res.Baseline.Status, res.Recheck.Detail)
	return res
}

// waitBetween держит паузу между батчами. false означает «контекст отменили
// раньше, чем пауза кончилась».
func waitBetween(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return true
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// probeBatch гоняет батч параллельно и возвращает результаты В ПОРЯДКЕ ВХОДА.
// Порядок важен: победитель выбирается по позиции в файле, а не по тому, кто
// первым ответил.
func probeBatch(ctx context.Context, addr string, batch []Candidate, cfg SweepConfig, hint time.Duration) []ProbeResult {
	out := make([]ProbeResult, len(batch))
	var wg sync.WaitGroup
	for i, c := range batch {
		wg.Add(1)
		go func(i int, c Candidate) {
			defer wg.Done()
			out[i] = Probe(ctx, addr, c.Name, cfg.Probe, hint)
		}(i, c)
	}
	wg.Wait()
	return out
}
