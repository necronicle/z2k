// Package classify измеряет ФУНКЦИЮ РЕШЕНИЯ DPI вместо перебора стратегий.
//
// Блокчек ищет в пространстве стратегий: гоняет N плеч и смотрит, какое прошло.
// Это O(N) соединений, каждое с таймаутом, и результат ничего не говорит о
// том, ПОЧЕМУ плечо сработало — значит на соседней линии он не переносится.
//
// Здесь постановка другая. DPI — это функция: берёт байты соединения и решает
// «пропустить» или «убить». Функцию можно зондировать напрямую, не имея на
// руках ни одной рабочей стратегии, если есть две вещи:
//
//	триггер — байты, которые надёжно вызывают блокировку;
//	оракул  — чем «прошло» отличается от «убито».
//
// Меняя ТОЛЬКО способ записи одного и того же триггера, мы читаем структуру
// матчера, а из структуры уже следует семейство обхода:
//
//	разрез в позиции p проходит, а p+1 нет  -> префиксный матчер, сигнатура
//	                                            кончается на p+1, режем внутри
//	ни один разрез не проходит              -> поток пересобирается (или блок
//	                                            вообще не по содержимому)
//	разрез с большой паузой всё ещё проходит -> буфера пересборки нет вовсе
//
// Замер 2026-08-28, шлюз WhatsApp, живая линия: границу нашли на четвёртом
// байте, и она в точности совпала с открытой сигнатурой протокола "WA\x06\x03".
// Шесть зондов вместо пятидесяти плеч, и вдобавок ответ на вопрос, какого
// класса коробка стоит у провайдера.
//
// ЧЕГО ЭТОТ ПАКЕТ НЕ УМЕЕТ (сознательно, а не по недосмотру). Всё здесь
// делается обычным сокетом: разрез — это TCP_NODELAY плюс пауза между
// записями. Фейки с битой суммой, TTL, умирающий до сервера, и seqovl требуют
// крафта пакетов, то есть сырых сокетов либо прогона через nfqws2. Это
// следующий слой, и он лишь расширяет дерево — верхняя развилка («пересобирает
// или нет») отсекает половину вариантов и берётся отсюда.
//
// И ограничение, которое не снимется ничем: всё это про блокировку ПО
// СОДЕРЖИМОМУ. Троттлинг по адресу назначения и IP-блок так не
// диагностируются — там молчат все зонды разом, и вердикт будет
// VerdictOpaque, а не «нужна такая-то стратегия».
package classify

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
	"time"
)

// Z2KBypassMark — метка, по которой правила NFQUEUE пропускают пакет мимо
// нашего десинка. Зонд обязан ходить сырым путём: иначе он меряет не коробку
// провайдера, а наш обход поверх неё.
const Z2KBypassMark = 0x40000000

// Verdict — класс блокировки, опознанный по форме отклика.
type Verdict string

const (
	// VerdictClear — триггер проходит как есть. Обходить нечего.
	VerdictClear Verdict = "clear"
	// VerdictPrefix — префиксный матчер без пересборки: разрез внутри
	// сигнатуры её ломает. Самый частый и самый дешёвый в обходе случай.
	VerdictPrefix Verdict = "prefix"
	// VerdictWholePacket — матчер требует пакет целиком: проходит ЛЮБОЙ
	// разрез, границы сигнатуры нет.
	VerdictWholePacket Verdict = "whole_packet"
	// VerdictOpaque — разрез не помогает, но контроль проходит: значит решение
	// принимается ПО СОДЕРЖИМОМУ, и коробка пересобирает поток. Разрез тут
	// бесполезен, нужен следующий слой зондов (фейк, TTL, seqovl).
	VerdictOpaque Verdict = "opaque"
	// VerdictInconclusive — контроль не прошёл, базовой линии нет. Молчание
	// контроля значит одно из двух: либо режут адрес, либо сервер просто не
	// обслуживает имя, которым мы его позвали. Отличить это без имени,
	// заведомо обслуживаемого ЭТИМ сервером, нельзя — и выдавать догадку за
	// вердикт нельзя тем более.
	//
	// Поле 2026-08-28: googlevideo. Контроль со случайным именем получил
	// тишину, инструмент объявил «режут по адресу, стратегией не лечится», а
	// с нашим обходом тот же адрес отдавал ServerHello за 292 мс. Вердикт был
	// не просто неточен — он был противоположен правде.
	VerdictInconclusive Verdict = "inconclusive"
	// VerdictAddress — молчит и контрольная нагрузка тоже. Содержимое ни при
	// чём: режут по адресу, порту или сети. Никакая стратегия десинка этого не
	// снимает, ответ — туннель.
	VerdictAddress Verdict = "address"
	// VerdictPoisonable — поток пересобирается, разрез бесполезен, но буфер
	// пересборки удалось отравить: нашлась разница между тем, что глотает
	// коробка, и тем, что выбрасывает сервер. Она и есть стратегия.
	VerdictPoisonable Verdict = "poisonable"
	// VerdictFlaky — измерения не воспроизводятся. Вердикт не выносим:
	// соврать здесь хуже, чем промолчать.
	VerdictFlaky Verdict = "flaky"
	// VerdictUnreachable — до цели нет даже TCP. Мерить нечего.
	VerdictUnreachable Verdict = "unreachable"
	// VerdictResponse — запрос проходит, режут ОТВЕТ.
	//
	// Класс существует только у TLS 1.2, где сертификат сервера едет открытым
	// текстом и содержит имя. Замер одного направления объявлял бы такой домен
	// «чистым», человек шёл искать поломку у себя, а резали ответ.
	VerdictResponse Verdict = "response"
)

// Result — что показал прогон.
type Result struct {
	Target   string  `json:"target"`
	Verdict  Verdict `json:"verdict"`
	Reason   string  `json:"reason"`
	Repeats  int     `json:"repeats"`
	Probes   int     `json:"probes"`
	Duration string  `json:"duration"`

	// TriggerLen — длина триггера в байтах.
	TriggerLen int `json:"trigger_len"`
	// Boundary — первая позиция разреза, которая УЖЕ не проходит. Значит
	// сигнатура кончается здесь, и резать надо строго левее. 0 — границы нет.
	Boundary int `json:"boundary,omitempty"`
	// SplitPos — рекомендуемая позиция разреза (0 — рекомендации нет).
	SplitPos int `json:"split_pos,omitempty"`
	// Reassembles — верно, если разрез с длинной паузой перестаёт работать,
	// то есть у коробки есть буфер пересборки с таймаутом.
	Reassembles *bool `json:"reassembles,omitempty"`
	// Strategy — готовая строка для --lua-desync, пустая если вердикт не
	// даёт рекомендации.
	Strategy string `json:"strategy,omitempty"`
	// CoversTLS12 — покрывает ли найденный приём СТАРЫХ клиентов.
	//
	// Один сайт в доме открывают и свежий браузер по TLS 1.3, и телевизор по
	// 1.2. Приветствия у них разные, и коробка на них реагирует по-разному.
	// nil значит «не проверяли» и отличается от false: «не проверено» и
	// «проверено, не покрывает» — разные вещи.
	CoversTLS12 *bool `json:"covers_tls12,omitempty"`
	// Response — итог зонда ответного направления. Заполняется только там, где
	// запрос признан проходящим: если режут запрос, про ответ говорить рано.
	Response *ResponseResult `json:"response,omitempty"`
	// Props — СВОЙСТВА КОРОБКИ, а не список удачных попыток.
	//
	// Разница принципиальная и в ней весь смысл затеи. Перебор плеч отвечает
	// «сработало тридцать восьмое» — знание, которое никуда не переносится.
	// Свойства отвечают «сумму не проверяет, стоит на девятом хопе, TLS
	// разбирает, переупорядочивание не держит», и уже ИЗ НИХ собирается
	// стратегия. То же знание годится для другого хоста и другой линии.
	Props Properties `json:"props"`
	// Path — каким из трёх путей получен ответ. Различать их важно: это и есть
	// мера того, насколько инструмент ушёл от перебора.
	//   "свойство" — ответила фаза вопросов о коробке;
	//   "собрано"  — стратегия построена из вектора свойств;
	//   "перебор"  — вектор не помог, ответ нашёлся запасным перебором.
	Path string `json:"path,omitempty"`
	// Composed — стратегия СОБРАНА из вектора свойств, а не найдена перебором.
	// Ложь при найденной стратегии означает, что вектор не сработал и ответ
	// пришёл из запасного перебора — то есть модель этот случай не описывает.
	Composed bool `json:"composed"`
	// RawUsable — прошла ли самопроверка сырого слоя. Ложь означает, что
	// отрицательный результат отравления ничего не доказывает.
	RawUsable bool `json:"raw_usable"`

	// Trace — сырые наблюдения, по одной строке на зонд. Нужны, чтобы вердикт
	// можно было перепроверить руками, а не верить на слово.
	Trace []Observation `json:"trace"`
}

// Properties — что удалось узнать о самой коробке. nil в булевых полях
// означает «не измерено», а не «нет»: молчать честнее, чем догадываться.
type Properties struct {
	// Reassembles — склеивает ли поток перед разбором.
	Reassembles *bool `json:"reassembles,omitempty"`
	// ParsesL7 — разбирает ли протокол. Ложь означает, что коробка сравнивает
	// байты: тогда приманкой годится набивка. Истина — что мусор она
	// пропустит мимо и приманка обязана быть правдоподобной.
	ParsesL7 *bool `json:"parses_l7,omitempty"`
	// ValidatesChecksum — проверяет ли контрольную сумму TCP. Ложь означает,
	// что сегмент с битой суммой она съест, а сервер выбросит: готовая щель.
	ValidatesChecksum *bool `json:"validates_checksum,omitempty"`
	// ToleratesReorder — держит ли сегменты, пришедшие не по порядку.
	ToleratesReorder *bool `json:"tolerates_reorder,omitempty"`
	// ToleratesLeftOverlap — правильно ли обрабатывает перекрытие слева.
	ToleratesLeftOverlap *bool `json:"tolerates_left_overlap,omitempty"`
	// CountsDuplicates — считает ли повторы одного сегмента как ретрансмиты.
	CountsDuplicates *bool `json:"counts_duplicates,omitempty"`
	// InspectsSYN — разбирает ли полезную нагрузку в SYN.
	InspectsSYN *bool `json:"inspects_syn,omitempty"`
	// HopTTL — наименьший TTL, при котором фальшивка до коробки ещё доходит,
	// а до сервера уже нет. Это её расстояние в хопах: не только стратегия,
	// но и адрес коробки в сети.
	HopTTL int `json:"hop_ttl,omitempty"`
}

// Observation — один зонд: как писали и что получили.
type Observation struct {
	Probe  string `json:"probe"`
	Cuts   []int  `json:"cuts,omitempty"`
	DelayM int    `json:"delay_ms,omitempty"`
	Pass   int    `json:"pass"`
	Fail   int    `json:"fail"`
	Err    string `json:"err,omitempty"`
}

// Trigger — что шлём и как понимаем, что ответ пришёл.
type Trigger struct {
	// Name попадает в вердикт, чтобы было видно, чем мерили.
	Name string
	// Payload — байты, вызывающие блокировку.
	Payload []byte
	// SNIOffset/SNILen — где в нагрузке лежит имя хоста, 0 если неизвестно.
	SNIOffset, SNILen int
	// Accept решает, является ли прочитанное доказательством, что триггер
	// дошёл до сервера. Пустой ответ доказательством НЕ является.
	Accept func([]byte) bool
}

// Options — настройки прогона. Нули заменяются разумными умолчаниями.
type Options struct {
	// Repeats — сколько раз повторяется КАЖДЫЙ зонд. Вердикт выносится только
	// при единогласии: одна случайная потеря пакета иначе назначила бы
	// границу сигнатуры не туда, а по ней потом строится стратегия.
	Repeats int
	// Timeout — сколько ждём ответа. Блокировка проявляется молчанием,
	// поэтому это НИЖНЯЯ граница длительности каждого неудачного зонда.
	Timeout time.Duration
	// WriteGap — пауза между записями. Нужна, чтобы записи гарантированно
	// разъехались по разным сегментам, а не слиплись в один.
	WriteGap time.Duration
	// LongGap — пауза для проверки на пересборку.
	LongGap time.Duration
	// AllowLoopback снимает защиту от цели на localhost. В проде такая цель
	// означает, что имя разрезолвилось не туда, и тихо мерить пустоту нельзя;
	// в тестах поддельная коробка живёт именно там.
	AllowLoopback bool
	// Only — прогнать ТОЛЬКО гипотезу с этим именем. Нужно для отладки самих
	// зондов: одна гипотеза это две посылки, её видно в дампе целиком, и с
	// боевым плечом её можно сверить побайтово.
	Only string
	// Skip — гипотезы, которые НЕ пробовать. Нужен поиску общего приёма для
	// двух приветствий: находку на старом перепроверяют на новом, и если она
	// не прошла, перебор надо продолжить со следующей, а не получить ту же.
	Skip map[string]bool
	// JointBudget — потолок времени на поиск приёма, общего для обоих
	// приветствий TLS. Ноль — взять умолчание пакета.
	JointBudget time.Duration
	// CrossCheckTLS12 — искать приём, который возьмёт и старые устройства.
	//
	// Режим выбирает человек: проверка на старом приветствии и поиск общего
	// приёма стоят минуты (замер 04.09: 3 с против 4 минут), и решать за него,
	// нужен ли ему телевизор и сколько он готов ждать, мы не можем.
	CrossCheckTLS12 bool
	// accept — фильтр находок. Перебор зовёт его на КАЖДОЙ сработавшей
	// гипотезе; вернул false — перебор идёт дальше, как будто гипотеза не
	// сработала.
	//
	// Нужен поиску приёма, общего для двух приветствий TLS. Наивно он делался
	// перезапуском всего перебора на каждую отвергнутую находку, и на
	// www.instagram.com это стоило 3 м 45 с при потолке задачи в 180 с. С
	// фильтром перебор идёт ОДИН раз, а каждая находка тут же проверяется на
	// втором приветствии.
	accept func(poison) bool
	// NoRaw выключает сырые зонды. Они требуют root и AF_INET/SOCK_RAW, зато
	// только они отвечают на вопрос «чем травить пересобирающую коробку».
	NoRaw bool
	// ControlVouched — оператор ЯВНО назвал имя для контроля и ручается, что
	// сервер его обслуживает. Только тогда молчание контроля значит блок по
	// адресу; иначе это «база не установлена».
	ControlVouched bool
	// Control — заведомо безобидная нагрузка на ТУ ЖЕ цель. Нужна, чтобы
	// отличить блокировку по содержимому от блокировки по адресу: если молчит
	// и она, содержимое ни при чём. Пустой Payload отключает проверку.
	Control Trigger
	// Dialer позволяет подменить установку соединения в тестах.
	Dialer func(ctx context.Context, addr string) (net.Conn, error)
}

func (o *Options) withDefaults() {
	if o.Repeats <= 0 {
		o.Repeats = 3
	}
	if o.Timeout <= 0 {
		o.Timeout = 6 * time.Second
	}
	if o.WriteGap <= 0 {
		o.WriteGap = 60 * time.Millisecond
	}
	if o.LongGap <= 0 {
		o.LongGap = 700 * time.Millisecond
	}
	if o.Dialer == nil {
		o.Dialer = func(ctx context.Context, addr string) (net.Conn, error) {
			// Та же метка и на обычных сокетах: сокетные зонды (целиком,
			// разрез, контроль) обязаны идти мимо десинка ровно так же, как
			// сырые, иначе половина дерева меряет одно, половина другое.
			d := net.Dialer{Control: markControl}
			return d.DialContext(ctx, "tcp", addr)
		}
	}
}

// Run прогоняет дерево зондов по адресу addr ("host:port").
// Именованный возврат здесь обязателен: отложенная функция проставляет
// Duration, а при возврате по значению она правила бы уже скопированную
// структуру — поле молча уезжало бы пустым.
func Run(ctx context.Context, addr string, tr Trigger, opt Options) (res Result) {
	opt.withDefaults()
	start := time.Now()
	res = Result{
		Target:     addr,
		Repeats:    opt.Repeats,
		TriggerLen: len(tr.Payload),
	}
	defer func() { res.Duration = time.Since(start).Round(time.Millisecond).String() }()

	// Цель проверяем ДО зондов. Пустой или неразобранный адрес давал уверенный
	// вердикт «режут по адресу» — на пустоте молчит всё, и инструмент честно
	// сообщал бы о блокировке там, где ошибся оператор. Врать так нельзя.
	if h, pstr, err := net.SplitHostPort(addr); err != nil || h == "" || pstr == "" {
		res.Verdict = VerdictFlaky
		res.Reason = "адрес не разобран, ожидается host:port"
		return res
	} else if ip := net.ParseIP(h); ip != nil && !opt.AllowLoopback && (ip.IsLoopback() || ip.IsUnspecified()) {
		res.Verdict = VerdictFlaky
		res.Reason = "цель указывает на localhost — мерить нечего, проверь как резолвится имя"
		return res
	}
	if len(tr.Payload) < 2 {
		res.Verdict = VerdictFlaky
		res.Reason = "триггер короче двух байт — резать нечего"
		return res
	}

	// 1. БАЗА. Триггер целиком, одной записью. Если проходит — блокировки по
	// содержимому нет, и всё остальное дерево не имеет смысла.
	base := measure(ctx, addr, tr, opt, "whole", nil, opt.WriteGap, &res)
	switch {
	case base.err != nil && base.pass == 0:
		res.Verdict = VerdictUnreachable
		res.Reason = "нет TCP до цели: " + base.err.Error()
		return res
	case base.pass == opt.Repeats:
		// Запрос проходит. Но это ещё не «обходить нечего»: у TLS 1.2
		// сертификат сервера идёт открытым текстом, и коробка может пропустить
		// запрос, а убить ОТВЕТ. Замер одного направления объявил бы такой
		// домен чистым, и вердикт был бы противоположен правде.
		res.Verdict = VerdictClear
		res.Reason = "триггер проходит как есть — обходить нечего"
		if sni := triggerSNI(tr); sni != "" {
			rr := ProbeResponse(ctx, addr, sni, opt)
			res.Response = &rr
			res.Probes += 2 * opt.Repeats
			switch rr.Verdict {
			case RespBlocked:
				res.Verdict = VerdictResponse
				res.Reason = rr.Reason
			case RespNotApplicable, RespFlaky:
				// «Не проверено» обязано быть видно. Молча оставить «чисто»
				// значило бы выдать непроверенное за проверенное.
				res.Reason += " (ответное направление: " + rr.Reason + ")"
			}
		}
		return res
	case base.pass > 0:
		res.Verdict = VerdictFlaky
		res.Reason = fmt.Sprintf("база не воспроизводится: %d прошло из %d", base.pass, opt.Repeats)
		return res
	}

	// 2. РЕЗАТЬ ВООБЩЕ ПОМОГАЕТ? Разрез после первого байта — самый агрессивный
	// из возможных: в первом сегменте остаётся один байт. Если и он не
	// проходит, никакая точка разреза не пройдёт тем более, и дальше искать
	// границу бессмысленно.
	one := measure(ctx, addr, tr, opt, "split", []int{1}, opt.WriteGap, &res)
	if one.pass == 0 {
		// 2а. КОНТРОЛЬ. Разрез не спас — но прежде чем говорить «пересборка»,
		// надо исключить, что содержимое вообще ни при чём. Шлём на ту же цель
		// безобидную нагрузку: пройдёт — значит режут именно наши байты;
		// промолчит — значит режут адрес, и десинк тут не поможет ничем.
		controlOK := true
		if len(opt.Control.Payload) > 0 {
			ctl := measure(ctx, addr, opt.Control, opt, "control", nil, opt.WriteGap, &res)
			controlOK = ctl.pass > 0
		}
		// МОЛЧАНИЕ КОНТРОЛЯ — НЕ ПОВОД ЗАКОНЧИТЬ.
		//
		// Раньше здесь стоял ранний возврат, и он оказался тупиком. Поле
		// 2026-08-28, googlevideo: тот фронтенд обслуживает ТОЛЬКО имена
		// *.googlevideo.com, а они все под блокировкой — безобидного имени для
		// контроля не существует в природе, и инструмент отказывался мерить
		// цель, которую наш же обход берёт 10 раз из 10.
		//
		// Перебор гипотез при этом полезен сам по себе: сработавшая отрава
		// ДОКАЗЫВАЕТ, что решение принимается по содержимому, — то есть даёт
		// ответ, за которым мы и звали контроль. Поэтому идём дальше, а
		// вердикт без базы просто не будет утверждать лишнего.
		// 2б. ОТРАВЛЕНИЕ БУФЕРА. Разрез бесполезен, но коробка всё же решает по
		// содержимому — значит она этот контент где-то накапливает. Подсовываем
		// сегмент в ту же область последовательности, который коробка проглотит,
		// а сервер выбросит, и смотрим, пройдёт ли после этого правда. Перебор
		// идёт по гипотезам «чем именно они расходятся», а не по плечам.
		if !opt.NoRaw && rawSupported() {
			if hit, ok := sweepPoisons(ctx, addr, tr, opt, &res); ok {
				_ = controlOK
				res.Verdict = VerdictPoisonable
				res.Boundary = 0
				res.Strategy = strategyForPoison(hit)
				res.Reason = "поток пересобирается, но буфер травится: коробка глотает «" + hit.name + "», сервер выбрасывает"
				crossCheckTLS12(ctx, addr, tr, opt, &res, hit.name)
				return res
			}
		}
		if !controlOK {
			if opt.ControlVouched {
				res.Verdict = VerdictAddress
				res.Reason = "молчит и контроль на имени, за которое ручается оператор, и ни одна гипотеза не сработала — похоже на блок по адресу"
			} else {
				res.Verdict = VerdictInconclusive
				res.Reason = "контроль не ответил и отравить не удалось: базы нет, отличить блок по адресу от нехватки гипотез нельзя"
			}
			return res
		}
		res.Verdict = VerdictOpaque
		res.Reason = "разрез не помогает, контроль проходит, отравить буфер не удалось — содержимое важно, но чем брать, зондами не нашли"
		if !res.RawUsable {
			res.Reason = "разрез не помогает, контроль проходит; сырые зонды НЕ РАБОТАЮТ (самопроверка не прошла) — про отравление вывода нет"
		}
		if opt.NoRaw || !rawSupported() {
			res.Reason = "разрез не помогает, а контроль проходит: решение по содержимому, поток пересобирается — сырые зонды выключены или недоступны"
		}
		return res
	}
	if one.pass != opt.Repeats {
		res.Verdict = VerdictFlaky
		res.Reason = fmt.Sprintf("разрез pos=1 не воспроизводится: %d из %d", one.pass, opt.Repeats)
		return res
	}

	// 3. ЕСТЬ ЛИ БУФЕР ПЕРЕСБОРКИ. Тот же разрез, но с паузой в сотни
	// миллисекунд. Коробка без буфера ведёт себя так же; коробка с буфером и
	// таймаутом успевает склеить сегменты и снова опознать сигнатуру.
	long := measure(ctx, addr, tr, opt, "split-long", []int{1}, opt.LongGap, &res)
	reass := long.pass == 0
	res.Reassembles = &reass
	res.Props.Reassembles = &reass

	// 4. ГРАНИЦА СИГНАТУРЫ — двоичным поиском. Инвариант: pos=1 проходит,
	// а какая-то позиция правее уже нет. Ищем ПЕРВУЮ непроходящую.
	// Если не проходит ни одна правее — граница на длине триггера, то есть
	// матчер требует пакет целиком.
	lo, hi := 1, len(tr.Payload) // lo проходит, hi — кандидат на «уже нет»
	last := measure(ctx, addr, tr, opt, "split", []int{len(tr.Payload) - 1}, opt.WriteGap, &res)
	if last.pass == opt.Repeats {
		res.Verdict = VerdictWholePacket
		res.Reason = "проходит любой разрез — матчер требует пакет целиком"
		res.SplitPos = 1
		res.Strategy = strategyFor(1)
		crossCheckTLS12(ctx, addr, tr, opt, &res, "")
		return res
	}
	hi = len(tr.Payload) - 1
	for hi-lo > 1 {
		mid := (lo + hi) / 2
		m := measure(ctx, addr, tr, opt, "split", []int{mid}, opt.WriteGap, &res)
		switch {
		case m.pass == opt.Repeats:
			lo = mid
		case m.pass == 0:
			hi = mid
		default:
			res.Verdict = VerdictFlaky
			res.Reason = fmt.Sprintf("разрез pos=%d не воспроизводится: %d из %d", mid, m.pass, opt.Repeats)
			return res
		}
	}

	res.Verdict = VerdictPrefix
	res.Boundary = hi
	res.SplitPos = 1
	res.Strategy = strategyFor(1)
	res.Reason = fmt.Sprintf("префиксный матчер: сигнатура кончается на байте %d, разрез левее её ломает", hi)
	crossCheckTLS12(ctx, addr, tr, opt, &res, "")
	if reass {
		res.Reason += "; при паузе " + opt.LongGap.String() + " блок возвращается — у коробки есть буфер пересборки"
	}
	return res
}

// poison — чем отравляем буфер пересборки. Смысл каждого варианта один:
// коробка обязана сегмент проглотить, сервер — выбросить. Различаются они
// только тем, ЧЕМ именно сервер его забракует.
type poison struct {
	name string
	// ttl: 0 — как обычно; >0 — пакет умрёт по дороге, не дойдя до сервера.
	ttl int
	// badsum: испортить контрольную сумму TCP.
	badsum bool
	// seqShift: сдвинуть номер последовательности за окно.
	seqShift int32
	// md5: добавить опцию TCP-MD5, которой сервер не ждёт.
	md5 bool
	// decoy: чем набивать фальшивый сегмент. Пусто — байты-заполнитель;
	// "hello" — правдоподобное приветствие с безобидным именем.
	//
	// РАЗЛИЧИЕ НЕ КОСМЕТИЧЕСКОЕ. Коробка, которая РАЗБИРАЕТ TLS, мусор
	// проигнорирует и продолжит ждать настоящий ClientHello — отравление
	// провалится, хотя механизм рабочий. Проглотит она только то, что похоже
	// на приветствие. Наше боевое плечо для facebook именно так и устроено:
	// фальшивка это ClientHello с чужим именем, а не набивка.
	decoy string
	// decoyPayload — готовые байты приманки, подставляются перед зондом.
	decoyPayload []byte
	// disorder: слать сегменты НЕ ПО ПОРЯДКУ — сначала хвост приветствия,
	// потом голову. Коробка, читающая поток как он приходит, сигнатуру не
	// соберёт; сервер соберёт, для него порядок не важен.
	disorder bool
	// tcpTS — положить в фальшивку метку времени со сдвигом назад. Боевые
	// плечи ставят tcp_ts=-1000: сервер такую метку забракует как устаревшую,
	// а коробка, метки не сверяющая, сегмент возьмёт.
	tcpTS bool
	// ipIDZero — обнулить поле идентификатора IP. Ещё одна мелочь из боевых
	// плеч (ip_id=zero), по которой сегмент можно отличить от настоящего.
	ipIDZero bool
	// gapMS — пауза между копиями фальшивки, миллисекунды. Ноль значит
	// вплотную. Величина измеряемая: боевое плечо обходится ДВУМЯ копиями с
	// разрывом в 78 мс, а моей плотной очереди нужно семь. Если у счётчика
	// коробки есть временное окно, плотная очередь и растянутая пара для него
	// не одно и то же — и тогда порог обязан упасть с ростом паузы.
	gapMS int
	// synData — положить приветствие ПРЯМО В SYN. По стандарту данных там не
	// ждут, и коробка вправе их не разбирать: сигнатура проезжает мимо неё, а
	// сервер, поддерживающий TCP Fast Open или просто терпимый к payload в
	// SYN, их примет. Отдельный механизм, а не вариант уже покрытых.
	synData bool
	// oob — байт ВНЕ ПОЛОСЫ (флаг URG плюс указатель). Сервер по правилам
	// изымает его из потока, коробка, читающая всё подряд, — оставляет.
	// Получается, что собранные ими байты расходятся ровно на один символ,
	// вставленный в середину сигнатуры.
	oob bool
	// fakeBetween — фальшивку класть МЕЖДУ кусками правды, а не перед всеми.
	// Размещение решает: сегодняшний замер показал, что фальшивка отдельной
	// посылкой перед перекрытием работает там, где та же приманка внутри
	// перекрывающего сегмента — нет.
	fakeBetween bool
	// repeats — сколько копий фальшивки слать подряд. Ноль и единица значат
	// одно и то же. Боевые плечи ставят 4–8: одиночную копию коробка может
	// потерять или отбросить, а серия повышает шанс, что хотя бы одна ляжет в
	// её буфер. Сервер выбросит их все по одной и той же причине, так что
	// цена серии — только трафик.
	repeats int
	// hasFake — нужна ли отдельная посылка-фальшивка. Приёмы независимы, и
	// признак «фальшивка есть» отделён от того, КАК подаётся правда.
	// seqovlExact — длину перекрытия взять РАВНОЙ длине приманки, а не задавать
	// числом. Боевое плечо ставит seqovl=681 с образцом
	// tls_clienthello_www_google_com: 681 — это не магия, это длина целого
	// правильного приветствия. Коробка разбирает его как валидный ClientHello
	// к чужому имени и своего не находит.
	//
	// Задать длину числом и добить остаток набивкой — не то же самое: запись
	// получается битой, и коробка её отбрасывает целиком. Замер 2026-08-29:
	// два хоста, которые арсенал берёт этим плечом, на моей набивке не
	// поддавались, потому что приманка была не приветствием, а огрызком.
	seqovlExact bool
	// seqovl: перекрытие последовательностей. Механизм ДРУГОЙ, а не вариант
	// отравления. Фальшивка не ложится в ту же область, а начинается ЛЕВЕЕ
	// настоящих данных и накрывает их: сегмент уходит с номером base-N и несёт
	// N байт приманки плюс настоящую нагрузку. Сервер левый край окна
	// подрезает и берёт правду; коробка, если разбирает поток с начала
	// сегмента, читает приманку и настоящего приветствия не видит вовсе.
	seqovl int
}

// hasFake — ставится ли отдельная посылка-приманка перед настоящими данными.
func (p poison) hasFake() bool {
	// synData и oob фальшивки не несут вовсе, fakeBetween ставит её сам и в
	// другом месте — общий путь отправки для них не годится.
	if p.synData || p.oob || p.fakeBetween {
		return false
	}
	return p.badsum || p.md5 || p.ttl > 0 || p.seqShift != 0
}

// poisons — набор гипотез, по одной на строку. Порядок от дешёвого к дорогому:
// badsum и md5 не требуют знания топологии, TTL требует перебора хопов.
func poisons() []poison {
	// ПОРЯДОК — ЭТО СТОИМОСТЬ. Неудачный зонд ждёт весь таймаут, удачный
	// отвечает мгновенно и обрывает перебор. Поэтому первыми идут гипотезы,
	// которые уже брали живые коробки: перекрытие в один байт (facebook),
	// разнесённые дубликаты (YouTube, googlevideo) и плотная семёрка. Всё
	// остальное — хвост, до которого доходит только незнакомый зверь.
	out := []poison{
		{name: "seqovl-1", seqovl: 1},
		{name: "badsum-x2-g20", badsum: true, repeats: 2, gapMS: 20},
		{name: "badsum-x2-g80", badsum: true, repeats: 2, gapMS: 80},
		{name: "badsum-x7", badsum: true, repeats: 7},
		{name: "disorder", disorder: true},
		{name: "badsum", badsum: true},
		{name: "md5", md5: true},
		{name: "seq-out-of-window", seqShift: -66000},
	}
	// ПРИМИТИВЫ, КОТОРЫХ НЕ БЫЛО. Все три — самостоятельные механизмы, а не
	// варианты уже покрытых, и каждый бьёт по своей особенности коробки.
	out = append(out, poison{name: "syndata"}, poison{name: "oob"})
	for _, n := range []int{1, 336} {
		out = append(out, poison{name: fmt.Sprintf("fakedsplit-%d", n), fakeBetween: true, badsum: true, seqovl: n})
	}
	out = append(out, poison{name: "fakedsplit", fakeBetween: true, badsum: true})
	out = append(out, poison{name: "fakedsplit+disorder", fakeBetween: true, badsum: true, disorder: true})
	out = append(out, poison{name: "fakedsplit-x7", fakeBetween: true, badsum: true, repeats: 7})
	// ТОЧНАЯ КОПИЯ БОЕВОГО ПЛЕЧА 1: семь копий фальшивки отдельной посылкой,
	// затем перекрытие слева длиной в целое приветствие. Собрано по дампу, а
	// не по описанию — три предыдущие попытки воспроизвести его по конфигу
	// промахнулись, каждая на своей детали.
	for _, r := range []int{7, 4, 2} {
		out = append(out, poison{name: fmt.Sprintf("fake-x%d+seqovl-hello", r),
			badsum: true, repeats: r, seqovlExact: true, decoy: "hello"})
		out = append(out, poison{name: fmt.Sprintf("fake-x%d+seqovl-681", r),
			badsum: true, repeats: r, seqovl: 681, decoy: "hello"})
		out = append(out, poison{name: fmt.Sprintf("fake-x%d+ttl62+seqovl-hello", r),
			badsum: true, ttl: 62, repeats: r, seqovlExact: true, decoy: "hello"})
	}
	// Перекрытие ДЛИНОЙ В ЦЕЛОЕ ПРИВЕТСТВИЕ — точная копия боевого приёма.
	out = append(out, poison{name: "seqovl-hello", seqovlExact: true, decoy: "hello"})
	out = append(out, poison{name: "seqovl-hello+disorder", seqovlExact: true, decoy: "hello", disorder: true})
	out = append(out, poison{name: "seqovl-hello+disorder+badsum", seqovlExact: true, decoy: "hello", disorder: true, badsum: true})
	// ТРОЙНЫЕ СВЯЗКИ. Боевое плечо 1 — фальшивка + перекрытие + сбитый
	// порядок ОДНОВРЕМЕННО. Приёмы по одному и парами такую коробку не берут,
	// и три хоста из девяти нерешённых стояли именно на нём.
	for _, n := range []int{1, 336, 681} {
		out = append(out, poison{name: fmt.Sprintf("seqovl-%d+disorder", n), seqovl: n, disorder: true})
		out = append(out, poison{name: fmt.Sprintf("seqovl-%d+disorder+hello", n), seqovl: n, disorder: true, decoy: "hello"})
		out = append(out, poison{name: fmt.Sprintf("seqovl-%d+disorder+badsum", n), seqovl: n, disorder: true, badsum: true})
	}
	// Перекрытие разной длины, с набивкой и с правдоподобной приманкой.
	for _, n := range []int{2, 4, 8, 16, 64, 336, 681} {
		out = append(out, poison{name: fmt.Sprintf("seqovl-%d", n), seqovl: n})
		out = append(out, poison{name: fmt.Sprintf("seqovl-%d+hello", n), seqovl: n, decoy: "hello"})
	}
	// Дубликаты: число копий × пауза. Обе оси нужны — одна без другой давала
	// неверную теорию (поле 2026-08-29: порог 7 оказался артефактом нулевой
	// паузы, при 20 мс хватает двух).
	for _, g := range []int{0, 20, 80, 300} {
		for _, n := range []int{2, 3, 4, 7} {
			nm := fmt.Sprintf("badsum-x%d-g%d", n, g)
			out = append(out, poison{name: nm, badsum: true, repeats: n, gapMS: g})
		}
	}
	// TTL сверху вниз: фальшивка должна пройти почти весь путь и умереть
	// перед сервером, а не сдохнуть у первого маршрутизатора.
	for _, t := range []int{62, 60, 58, 55, 50, 40, 20, 8} {
		out = append(out, poison{name: fmt.Sprintf("ttl-%d", t), ttl: t})
		out = append(out, poison{name: fmt.Sprintf("badsum+ttl-%d", t), badsum: true, ttl: t})
	}
	// Связки с порядком.
	out = append(out, poison{name: "disorder+badsum", disorder: true, badsum: true})
	out = append(out, poison{name: "disorder+badsum+hello", disorder: true, badsum: true, decoy: "hello"})
	for _, t := range []int{62, 58, 50} {
		out = append(out, poison{name: fmt.Sprintf("disorder+badsum+ttl-%d", t), disorder: true, badsum: true, ttl: t})
	}
	// Мелочи из боевых плеч — метка времени и обнулённый идентификатор.
	out = append(out, poison{name: "badsum+ts", badsum: true, tcpTS: true})
	out = append(out, poison{name: "badsum+ipid", badsum: true, ipIDZero: true})
	out = append(out, poison{name: "badsum+hello", badsum: true, decoy: "hello"})
	return out
}

// RawEcho — положительный контроль ПУТИ ДАННЫХ сырого слоя: рукопожатие своими
// руками, затем триггер как есть, без единого приёма. На цели, которая не под
// блокировкой, обязан вернуться ответ.
//
// Без него отрицательный результат перебора двусмыслен. Самопроверка
// рукопожатия доказывает, что сокеты и суммы в порядке, но НЕ доказывает, что
// сервер принимает наши сегменты с данными: там свои грабли — опции TCP,
// метки времени, размер окна. Поле 2026-08-29: 164 зонда подряд молчали, и
// отличить «коробка держит» от «сервер не берёт мои пакеты» было нечем.
func RawEcho(ctx context.Context, addr string, tr Trigger, timeout time.Duration) (bool, error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return false, err
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return false, errors.New("classify: имя не разрешается")
	}
	var ip net.IP
	for _, c := range ips {
		if v4 := c.To4(); v4 != nil {
			ip = v4
			break
		}
	}
	if ip == nil {
		return false, errors.New("classify: нет адреса IPv4")
	}
	var port int
	if _, e := fmt.Sscanf(portStr, "%d", &port); e != nil {
		return false, e
	}
	return probePoison(ctx, ip, uint16(port), tr, poison{name: "none"}, timeout)
}

// sweepPoisons перебирает гипотезы отравления и возвращает первую сработавшую.
//
// Порядок в poisons() не случайный: сначала то, что не требует знания
// топологии (битая сумма, MD5, номер вне окна), потом перебор TTL. TTL идёт
// последним не только по цене — сработавшее значение попутно называет хоп, на
// котором стоит коробка, и это самостоятельная находка.
func sweepPoisons(ctx context.Context, addr string, tr Trigger, opt Options, res *Result) (poison, bool) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return poison{}, false
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return poison{}, false
	}
	var ip net.IP
	for _, cand := range ips {
		if v4 := cand.To4(); v4 != nil {
			ip = v4
			break
		}
	}
	if ip == nil {
		return poison{}, false
	}
	var port int
	if _, e := fmt.Sscanf(portStr, "%d", &port); e != nil || port <= 0 {
		return poison{}, false
	}

	// САМОПРОВЕРКА СЫРОГО СЛОЯ. Свой TCP — это своё рукопожатие, свои
	// контрольные суммы и придержанное ядро; сломайся любая из этих частей, и
	// ВСЕ зонды дали бы «тишину», а мы прочитали бы её как «отравить не
	// удалось». Поэтому сперва гоняем по тому же пути безобидную нагрузку без
	// всякой отравы: не прошла — значит мерить нечем, и об этом надо сказать
	// прямо, а не выдавать отрицательный результат за находку.
	{
		obs := Observation{Probe: "raw-selftest"}
		for i := 0; i < opt.Repeats; i++ {
			ok, err := probeRawHandshake(ctx, ip, uint16(port), opt.Timeout)
			res.Probes++
			switch {
			case err != nil:
				obs.Fail++
				if obs.Err == "" {
					obs.Err = err.Error()
				}
			case ok:
				obs.Pass++
			default:
				obs.Fail++
			}
		}
		res.Trace = append(res.Trace, obs)
		if obs.Pass == 0 {
			res.RawUsable = false
			return poison{}, false
		}
	}
	res.RawUsable = true
	// Если правило подавления ядерного RST не встало, отрицательные исходы
	// сырых зондов ничего не значат: RST мог прилететь от нашего же ядра.
	// Сказать об этом обязаны — иначе своя поломка читается как свойство сети.
	if RawRSTRuleFailed() {
		res.Trace = append(res.Trace, Observation{
			Probe: "внимание:правило подавления RST не встало",
			Err:   "iptables отверг вставку; отрицательные исходы сырых зондов недостоверны",
		})
	}

	// СВОЙСТВА СПЕРВА, СТРАТЕГИЯ — ИЗ НИХ.
	//
	// Шесть вопросов вместо девяноста попыток. Каждый отвечает на что-то о
	// коробке, даже когда сам обхода не даёт, и заполняет вектор, из которого
	// стратегия СОБИРАЕТСЯ. Перебор ниже остаётся, но уже запасным путём —
	// для случаев, где собранное не сработало.
	if opt.Only == "" {
		if hit, ok := runProperties(ctx, ip, uint16(port), tr, opt, res); ok {
			if opt.acceptable(hit) {
				res.Path = "свойство"
				return hit, true
			}
		}
		for _, cand := range composeFromProps(res.Props, opt.Control.Payload) {
			if ctx.Err() != nil {
				break
			}
			if opt.Skip[cand.name] {
				continue
			}
			obs := Observation{Probe: cand.name, DelayM: cand.gapMS}
			pass := 0
			for i := 0; i < opt.Repeats; i++ {
				ok, err := probePoison(ctx, ip, uint16(port), tr, cand, opt.Timeout)
				res.Probes++
				if err == nil && ok {
					pass++
				}
			}
			obs.Pass, obs.Fail = pass, opt.Repeats-pass
			res.Trace = append(res.Trace, obs)
			if pass == opt.Repeats {
				if opt.acceptable(cand) {
					res.Composed, res.Path = true, "собрано"
					return cand, true
				}
			}
		}
	}

	for _, p := range poisons() {
		if ctx.Err() != nil {
			break
		}
		if opt.Only != "" && p.name != opt.Only {
			continue
		}
		if opt.Skip[p.name] {
			continue
		}
		obs := Observation{Probe: "poison:" + p.name, DelayM: p.gapMS}
		for i := 0; i < opt.Repeats; i++ {
			pp := p
			if pp.decoy == "hello" {
				pp.decoyPayload = opt.Control.Payload
				if pp.seqovlExact {
					// Длина перекрытия = длина приманки: в него ложится целое
					// приветствие, без набивки и без обрезки.
					pp.seqovl = len(opt.Control.Payload)
				}
			}
			ok, err := probePoison(ctx, ip, uint16(port), tr, pp, opt.Timeout)
			res.Probes++
			switch {
			case err != nil:
				obs.Fail++
				if obs.Err == "" {
					obs.Err = err.Error()
				}
			case ok:
				obs.Pass++
			default:
				obs.Fail++
			}
		}
		res.Trace = append(res.Trace, obs)
		// Единогласие обязательно: одна случайная удача назначила бы
		// стратегией то, что не работает.
		if obs.Pass == opt.Repeats {
			notePropsHit(&res.Props, p)
			if !opt.acceptable(p) {
				continue
			}
			if res.Path == "" {
				res.Path = "перебор"
			}
			return p, true
		}
		notePropsMiss(&res.Props, p)
	}
	return poison{}, false
}

// notePropsHit/notePropsMiss переводят исход зонда в свойство коробки.
// Именно здесь перебор перестаёт быть перебором: каждая попытка что-то
// РАССКАЗЫВАЕТ о коробке, даже когда не срабатывает.
func notePropsHit(pr *Properties, p poison) {
	t, f := true, false
	switch {
	case p.badsum:
		pr.ValidatesChecksum = &f // съела битую сумму
	case p.ttl > 0:
		pr.HopTTL = p.ttl
	case p.disorder:
		pr.ToleratesReorder = &f
	case p.seqovl > 0:
		pr.ToleratesLeftOverlap = &f
	}
	if p.decoy == "hello" {
		pr.ParsesL7 = &t // набивку не взяла, приветствие взяла
	}
}

func notePropsMiss(pr *Properties, p poison) {
	t := true
	switch {
	case p.badsum && p.decoy == "":
		pr.ValidatesChecksum = &t
	case p.disorder:
		pr.ToleratesReorder = &t
	case p.seqovl > 0 && p.decoy == "":
		pr.ToleratesLeftOverlap = &t
	}
}

// strategyForPoison переводит найденную разницу в термины nfqws2.
func strategyForPoison(p poison) string {
	if p.synData {
		return "--lua-desync=syndata:payload=tls_client_hello:dir=out"
	}
	if p.oob {
		return "--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:oob"
	}
	if p.fakeBetween {
		st := "--lua-desync=fakedsplit:payload=tls_client_hello:dir=out:pos=1"
		if p.badsum {
			st += ":badsum"
		}
		if p.repeats > 1 {
			st += fmt.Sprintf(":repeats=%d", p.repeats)
		}
		return st
	}
	if p.hasFake() && (p.seqovl > 0 || p.seqovlExact) {
		f := "--lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:tls_mod=rnd,dupsid,sni=www.google.com"
		if p.badsum {
			f += ":badsum"
		}
		if p.ttl > 0 {
			f += fmt.Sprintf(":ip_ttl=%d", p.ttl)
		}
		if p.repeats > 1 {
			f += fmt.Sprintf(":repeats=%d", p.repeats)
		}
		return f + " --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=681:seqovl_pattern=tls_clienthello_www_google_com"
	}
	if p.seqovlExact {
		st := "--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=681:seqovl_pattern=tls_clienthello_www_google_com"
		if p.disorder {
			st += " --lua-desync=multidisorder:payload=tls_client_hello:dir=out:pos=1,midsld"
		}
		return st
	}
	if p.seqovl > 0 && p.disorder {
		st := fmt.Sprintf("--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=%d", p.seqovl)
		if p.decoy == "hello" {
			st += ":seqovl_pattern=tls_clienthello_www_google_com"
		}
		return st + " --lua-desync=multidisorder:payload=tls_client_hello:dir=out:pos=1,midsld"
	}
	if p.disorder {
		st := "--lua-desync=multidisorder:payload=tls_client_hello:dir=out:pos=1,midsld"
		if p.hasFake() {
			// Связка: сперва фальшивка, следом настоящие сегменты вразнобой.
			f := "--lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls"
			if p.decoy == "hello" {
				f += ":tls_mod=rnd,dupsid,sni=www.google.com"
			}
			if p.badsum {
				f += ":badsum"
			}
			if p.ttl > 0 {
				f += fmt.Sprintf(":ip_ttl=%d", p.ttl)
			}
			if p.repeats > 1 {
				f += fmt.Sprintf(":repeats=%d", p.repeats)
			}
			return f + " " + st
		}
		return st
	}
	if p.seqovl > 0 {
		st := fmt.Sprintf("--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=%d", p.seqovl)
		if p.decoy == "hello" {
			st += ":seqovl_pattern=tls_clienthello_www_google_com"
		}
		return st
	}
	head := "--lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls"
	if p.badsum && p.ttl > 0 {
		return fmt.Sprintf("%s:badsum:ip_ttl=%d", head, p.ttl)
	}
	if p.decoy == "hello" {
		// Приманкой служит приветствие с чужим именем — ровно то, что даёт
		// tls_mod=sni=... в боевых плечах.
		head += ":tls_mod=rnd,dupsid,sni=www.google.com"
	}
	switch {
	case p.badsum:
		return head + ":badsum"
	case p.md5:
		return head + ":tcp_md5"
	case p.seqShift != 0:
		return fmt.Sprintf("%s:tcp_seq=%d", head, p.seqShift)
	case p.ttl > 0:
		return fmt.Sprintf("%s:ip_ttl=%d", head, p.ttl)
	}
	return ""
}

// strategyFor — как записать найденное в термины nfqws2.
func strategyFor(pos int) string {
	return fmt.Sprintf("--lua-desync=multisplit:payload=unknown:dir=out:pos=%d", pos)
}

type tally struct {
	pass, fail int
	err        error
}

// measure гоняет один зонд Repeats раз и записывает наблюдение в трассу.
func measure(ctx context.Context, addr string, tr Trigger, opt Options, name string, cuts []int, gap time.Duration, res *Result) tally {
	var t tally
	obs := Observation{Probe: name, Cuts: cuts, DelayM: int(gap / time.Millisecond)}
	for i := 0; i < opt.Repeats; i++ {
		if ctx.Err() != nil {
			break
		}
		ok, err := once(ctx, addr, tr, opt, cuts, gap)
		res.Probes++
		switch {
		case err != nil:
			t.fail++
			if t.err == nil {
				t.err = err
				obs.Err = err.Error()
			}
		case ok:
			t.pass++
		default:
			t.fail++
		}
	}
	obs.Pass, obs.Fail = t.pass, t.fail
	res.Trace = append(res.Trace, obs)
	return t
}

// once — одно соединение: пишем триггер по кускам, ждём ответ.
func once(ctx context.Context, addr string, tr Trigger, opt Options, cuts []int, gap time.Duration) (bool, error) {
	dctx, cancel := context.WithTimeout(ctx, opt.Timeout)
	defer cancel()
	c, err := opt.Dialer(dctx, addr)
	if err != nil {
		return false, err
	}
	defer c.Close()
	// Без этого ядро склеит наши записи в один сегмент, и весь замер
	// превратится в измерение самого себя.
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	_ = c.SetDeadline(time.Now().Add(opt.Timeout))

	for _, off := range splitOffsets(cuts, len(tr.Payload)) {
		if _, err := c.Write(tr.Payload[off.from:off.to]); err != nil {
			return false, err
		}
		if off.to < len(tr.Payload) {
			select {
			case <-time.After(gap):
			case <-dctx.Done():
				return false, dctx.Err()
			}
		}
	}

	buf := make([]byte, 4096)
	n, err := c.Read(buf)
	if err != nil {
		// Тишина и обрыв — это и есть «убито». Ошибкой зонда не считаем:
		// иначе блокировка выглядела бы как неисправность инструмента.
		if isSilence(err) {
			return false, nil
		}
		return false, nil
	}
	if n == 0 {
		return false, nil
	}
	if tr.Accept != nil && !tr.Accept(buf[:n]) {
		return false, nil
	}
	return true, nil
}

func isSilence(err error) bool {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return true
	}
	s := err.Error()
	return strings.Contains(s, "reset") || strings.Contains(s, "EOF") || strings.Contains(s, "closed")
}

type span struct{ from, to int }

// splitOffsets превращает список точек разреза в куски. Точки вне (0, len)
// отбрасываются: разрез в нуле и в конце — это не разрез.
func splitOffsets(cuts []int, n int) []span {
	cl := make([]int, 0, len(cuts))
	for _, c := range cuts {
		if c > 0 && c < n {
			cl = append(cl, c)
		}
	}
	sort.Ints(cl)
	out := make([]span, 0, len(cl)+1)
	prev := 0
	for _, c := range cl {
		if c == prev {
			continue
		}
		out = append(out, span{prev, c})
		prev = c
	}
	out = append(out, span{prev, n})
	return out
}

// acceptable — пропускает ли фильтр эту находку. Без фильтра годится любая.
func (o Options) acceptable(p poison) bool {
	if o.accept == nil {
		return true
	}
	return o.accept(p)
}
