package quicprobe

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/ipv4"
)

// Замер QUIC устроен ИНАЧЕ, чем TCP-классификатор, и не по прихоти.
//
// В TCP коробка выдаёт себя сама: RST — это инъекция, её видно, а SYN-ACK
// доказывает достижимость сервера. Поэтому там «нет» информативно, и можно
// двоичным поиском искать границу сигнатуры в потоке.
//
// В UDP инъекций нет вовсе: коробка молча дропает. Наблюдаемое — «ответ или
// тишина», а тишина имеет минимум четыре причины (съели по пути туда, съели
// ответ, сервер сам не принял, датаграмма потерялась). Разреза по позиции тоже
// нет: датаграмма атомарна, и укоротить её нельзя — клиентский Initial обязан
// быть не меньше 1200 байт, иначе сервер выбросит его сам (RFC 9000 §14.1).
//
// Отсюда конструкция:
//
//	1. Сначала добывается ОРАКУЛ — нагрузка на тот же адрес, которая заведомо
//	   отвечает. Без него мерить нечего, и это надо честно сказать, а не гадать.
//	2. Дальше вопросы задаются в направлении, где информативен ПОЛОЖИТЕЛЬНЫЙ
//	   исход: берём заблокированное имя, меняем ОДНО свойство записи и смотрим,
//	   не появился ли ответ. Ответ однозначен, тишина — нет, поэтому тишина
//	   никогда не становится основанием для вывода в одиночку.
//	3. Отдельно проверяется остаточная блокировка. Если она есть, тишина
//	   становится измеримой: после срабатывания коробка глушит и заведомо
//	   безобидные датаграммы, и это уже положительный сигнал.
//
// Методика взята из измерений GFW (USENIX Security 2025, Zohaib et al.,
// «Exposing and Circumventing SNI-based QUIC Censorship»). Там же — факты,
// которыми обоснованы отдельные зонды: срабатывание с одного клиентского
// Initial; остаточная блокировка 180 с по тройке (srcIP, dstIP, dstPort);
// состояние потока по четвёрке с таймаутом 60 с; отказ разбирать поток, если
// перед Initial прошла любая другая датаграмма; неспособность собрать
// ClientHello из нескольких кадров CRYPTO или нескольких датаграмм.
//
// ВАЖНО: это Китай, а не ТСПУ. Ни одно из тех ЧИСЕЛ сюда не перенесено — сюда
// перенесена только методика. Все значения ниже берутся замером на живой линии.

// Verdict — класс происходящего с доменом по QUIC.
type Verdict string

const (
	// VerdictClear — Initial проходит как есть, обходить нечего.
	VerdictClear Verdict = "clear"
	// VerdictContent — решение принимается ПО СОДЕРЖИМОМУ: контроль на тот же
	// адрес отвечает, наше имя — нет.
	VerdictContent Verdict = "content"
	// VerdictAddress — молчит и контроль, и зонд согласования версии. Значит
	// содержимое ни при чём: режут адрес, порт или UDP целиком. Десинком не
	// лечится.
	VerdictAddress Verdict = "address"
	// VerdictNoQUIC — путь жив (согласование версии отвечает), но на Initial
	// не отвечают ни с нашим именем, ни с нейтральным. Самый вероятный смысл:
	// хост не обслуживает HTTP/3. Это НЕ блокировка, и выдавать её за
	// блокировку — врать человеку.
	VerdictNoQUIC Verdict = "no_quic"
	// VerdictFlaky — измерения не воспроизводятся. Молчать честнее, чем врать.
	VerdictFlaky Verdict = "flaky"
	// VerdictUnreachable — до адреса нет даже пути.
	VerdictUnreachable Verdict = "unreachable"
	// VerdictLocalAddress — имя разрешается в приватный адрес. Мерить нечего:
	// датаграммы до провайдера вообще не доходят.
	//
	// Случай не экзотический, а частый: подменяют и роутер, и AdGuard, и наш
	// собственный редирект по хостлисту. Замер 04.09 на линии Марка:
	// rutracker.org локально разрешается в 10.171.171.171, тогда как 8.8.8.8 и
	// 1.1.1.1 отдают 188.186.154.79. Без этой проверки инструмент объявил бы
	// «режут адрес» и был бы неправ полностью: провайдер тут ни при чём.
	VerdictLocalAddress Verdict = "local_address"
)

// Properties — что показали вопросы к коробке.
//
// ФОРМУЛИРОВКИ НАМЕРЕННО ПРО ПРИЁМЫ, А НЕ ПРО УСТРОЙСТВО КОРОБКИ. Соблазн
// записать «коробка собирает кадры CRYPTO» велик, но это вывод из ТИШИНЫ, а
// тишина в UDP многозначна: приём мог не сработать и потому, что коробка
// собирает кадры, и потому, что она отбросила датаграмму по совсем другому
// признаку. Утверждать про механику можно только по ПОЛОЖИТЕЛЬНОМУ исходу:
// если приём прошёл, значит коробка на это свойство опирается — и такие
// выводы уходят в Findings.
//
// nil значит «не измеряли» и отличается от false намеренно: «не проверяли» и
// «проверили, не помогло» — разные вещи.
type Properties struct {
	// ResidualBlocking — единственное поле про саму коробку, и оно измерено
	// положительно: контроль отвечал, после срабатывания замолчал.
	ResidualBlocking *bool `json:"residual_blocking,omitempty"`
	// ResidualIgnoresSrcPort — держится ли остаточная блокировка при смене
	// исходного порта.
	ResidualIgnoresSrcPort *bool `json:"residual_ignores_src_port,omitempty"`

	// JunkAheadHelps — помогает ли мусорная датаграмма перед Initial.
	JunkAheadHelps *bool `json:"junk_ahead_helps,omitempty"`
	// SplitCryptoHelps — помогает ли разложить приветствие на кадры CRYPTO.
	SplitCryptoHelps *bool `json:"split_crypto_helps,omitempty"`
	// SplitDatagramsHelps — помогает ли разложить его на две датаграммы.
	SplitDatagramsHelps *bool `json:"split_datagrams_helps,omitempty"`
	// VersionTwoHelps — помогает ли вторая версия QUIC.
	VersionTwoHelps *bool `json:"version_two_helps,omitempty"`
	// ClearFixedBitHelps — помогает ли погашенный фиксированный бит.
	ClearFixedBitHelps *bool `json:"clear_fixed_bit_helps,omitempty"`
	// LowSourcePortHelps — помогает ли исходный порт не выше порта назначения.
	LowSourcePortHelps *bool `json:"low_source_port_helps,omitempty"`

	// FakeAhead — какая фальшивка перед настоящей датаграммой помогла.
	// Имя блоба — как оно зарегистрировано в движке.
	FakeAhead string `json:"fake_ahead,omitempty"`
	// FakeRepeats — сколько копий фальшивки понадобилось. Ноль — хватило одной.
	FakeRepeats int `json:"fake_repeats,omitempty"`
	// FakeTTL — TTL фальшивки, если помогла именно укороченная. Она обязана
	// умереть между коробкой и сервером: коробка её учтёт, сервер не увидит.
	FakeTTL int `json:"fake_ttl,omitempty"`
	// ServerTTLIn — TTL, с которым пришёл ответ сервера. СЫРОЙ ФАКТ, без
	// пересчёта в расстояние: замер 04.09 показал, что на один и тот же адрес
	// ICMP и QUIC отдают разные TTL (56 против 86), то есть отвечают разные
	// узлы и «расстояние» из одного наблюдения было бы выдумкой.
	ServerTTLIn int `json:"server_ttl_in,omitempty"`

	// FragSurvives — доживают ли IP-фрагменты до сервера НА ЭТОМ КАНАЛЕ.
	// Меряется на заведомо отвечающем имени, ДО всяких выводов о коробке.
	// Ложь означает, что всё семейство ipfrag на этой линии не обход, а тихое
	// убийство трафика, и предлагать его нельзя.
	FragSurvives *bool `json:"frag_survives,omitempty"`
	// FragArm — какое именно плечо фрагментации прошло.
	FragArm string `json:"frag_arm,omitempty"`

	// UDPLen — на сколько байт помогла добивка длины.
	UDPLen int `json:"udplen,omitempty"`
}

// Step — одна строка трассы. Нужна поддержке: по ней видно, что именно
// спросили у коробки и что она ответила.
type Step struct {
	Name     string `json:"name"`
	Sent     int    `json:"sent"`
	Answered int    `json:"answered"`
	// Refused — сколько раз пришёл ICMP «порт недоступен». Это ЕДИНСТВЕННЫЙ
	// в UDP отрицательный ответ, который что-то доказывает: датаграмма дошла
	// до хоста, а слушателя на порту нет. Без него «хост не обслуживает
	// HTTP/3» и «коробка молча дропает» выглядят одинаково.
	Refused int `json:"refused,omitempty"`
	// NotBuilt — сколько раз зонд не удалось СОБРАТЬ. Считается отдельно от
	// тишины намеренно: несобравшийся зонд ничего не доказывает, а сложенный с
	// молчанием он превратился бы в вывод «свойство не подтвердилось».
	NotBuilt int `json:"not_built,omitempty"`
	// TTLIn — TTL входящего пакета. Из него считается расстояние до сервера, а
	// значит и верхняя граница окна для фальшивки с укороченным TTL.
	TTLIn int    `json:"ttl_in,omitempty"`
	MS    int64  `json:"ms"`
	Note  string `json:"note,omitempty"`
}

// Result — что показал прогон.
type Result struct {
	Target   string  `json:"target"`
	Addr     string  `json:"addr"`
	Verdict  Verdict `json:"verdict"`
	Reason   string  `json:"reason"`
	Repeats  int     `json:"repeats"`
	Probes   int     `json:"probes"`
	Duration string  `json:"duration"`
	RTTMS    int64   `json:"rtt_ms,omitempty"`

	Props Properties `json:"props"`
	// Strategy — строка для --lua-desync, если нашёлся приём, который наш
	// движок УМЕЕТ исполнить. Пусто — значит исполнимого приёма не нашли.
	Strategy string `json:"strategy,omitempty"`
	// Findings — приёмы, которые в замере СРАБОТАЛИ, но которых движок сегодня
	// исполнить не может. Прятать их нельзя: это самый ценный выход замера.
	//
	// Сюда попадают ТОЛЬКО положительные находки. Панель по непустому списку
	// говорит человеку «домен пробивается, но приёмом, который движок не
	// умеет», и служебная заметка вроде «вопрос не задан» превратилась бы там
	// в обещание обхода, которого нет.
	Findings []string `json:"findings,omitempty"`
	// Notes — служебные оговорки о полноте самого замера: что осталось
	// неспрошенным и почему. Для поддержки, не для обещаний.
	Notes []string `json:"notes,omitempty"`
	Trace []Step   `json:"trace,omitempty"`
}

// Options — настройки прогона.
type Options struct {
	Port    int
	Repeats int
	// Timeout — сколько ждать ответа на одну датаграмму. Ноль — вывести из
	// измеренного RTT: у датаграмм одиночная потеря норма, а сервер повторяет
	// свой Initial по таймеру PTO (замер 04.09: +1052 и +2051 мс).
	Timeout time.Duration
	// Parallel — сколько зондов держать в воздухе. Зонды на разных пятёрках
	// друг другу не мешают, и это главное отличие от TCP: там конвейер, здесь
	// веер.
	Parallel int
	// Addr — слать по этому адресу вместо разрешения имени. Имя при этом
	// остаётся в SNI. Нужно там, где адрес известен, а имя всё равно решает:
	// проверка конкретного адреса из нескольких, и стенд в тестах.
	Addr          string
	AllowLoopback bool
}

func (o *Options) withDefaults() {
	if o.Port == 0 {
		o.Port = 443
	}
	if o.Repeats <= 0 {
		o.Repeats = 3
	}
	if o.Parallel <= 0 {
		o.Parallel = 6
	}
}

// neutralName — имя для контроля. Домен example.com зарезервирован IANA
// (RFC 2606), не блокируется и заведомо не встретится в списках. Случайная
// метка спереди убирает попадание в кэши и в состояние коробки.
func neutralName() string {
	var b [5]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("z%x.example.com", b)
}

func randomID(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

// Run измеряет, что происходит с доменом по QUIC.
func Run(ctx context.Context, host string, opt Options) Result {
	opt.withDefaults()
	started := time.Now()
	res := Result{
		Target:  net.JoinHostPort(host, strconv.Itoa(opt.Port)),
		Repeats: opt.Repeats,
	}
	finish := func(v Verdict, reason string) Result {
		res.Verdict, res.Reason = v, reason
		res.Duration = time.Since(started).Round(time.Millisecond).String()
		return res
	}

	addrs, err := resolveAll(ctx, host, opt)
	if err != nil {
		return finish(VerdictUnreachable, err.Error())
	}
	addr := addrs[0]
	res.Addr = addr.String()
	if !opt.AllowLoopback && isLocal(addr.IP) {
		return finish(VerdictLocalAddress, fmt.Sprintf(
			"имя разрешается в адрес %s из приватного диапазона — это подмена на уровне DNS "+
				"(роутер, AdGuard или свой редирект по хостлисту), а не блокировка провайдера. "+
				"Замерить, чем режут, можно только по настоящему адресу", addr.IP))
	}

	run := func(name string, mk func(int) probeSpec, timeout time.Duration) Step {
		st := measure(ctx, addr, opt, mk, timeout)
		st.Name = name
		res.Probes += st.Sent
		res.Trace = append(res.Trace, st)
		return st
	}

	// ШАГ 1. ОРАКУЛ. Нейтральное имя на ТОТ ЖЕ адрес. Если сервер на него
	// отвечает, у нас есть живая база, относительно которой измеримо всё
	// остальное. Замер 04.09: Google отвечает на случайное имя за 45 мс.
	base := run("контроль:нейтральное имя", func(int) probeSpec {
		return buildInitial(neutralName(), V1, 1200, 0)
	}, firstTimeout(opt))
	if base.Answered > 0 {
		res.RTTMS = base.MS
	}

	probeTimeout := opt.Timeout
	if probeTimeout == 0 {
		probeTimeout = deriveTimeout(base.MS)
	}

	if base.Answered == 0 {
		// База молчит. Прежде чем говорить «блокировка», надо отделить
		// «сервер не говорит по QUIC» от «режут адрес». Зонд согласования
		// версии не несёт содержимого вовсе: ответ на него доказывает, что
		// путь жив, независимо от того, что коробка думает про имена.
		if base.Refused > 0 {
			return finish(VerdictNoQUIC, fmt.Sprintf(
				"на UDP/%d у адреса %s никто не слушает — пришёл ICMP «порт недоступен». "+
					"Значит хост не обслуживает HTTP/3, и резать тут нечего",
				opt.Port, addr.IP))
		}
		vn := run("контроль:согласование версии", func(int) probeSpec {
			dcid, scid := randomID(8), randomID(8)
			return probeSpec{pkts: [][]byte{versionNegotiationProbe(dcid, scid, 1200)},
				dcid: dcid, ver: V1}
		}, probeTimeout)
		if vn.Answered == 0 {
			return finish(VerdictAddress,
				"молчит и контрольное имя, и зонд согласования версии: содержимое ни при чём, "+
					"режут адрес, порт или UDP целиком — десинком это не лечится")
		}
		return finish(VerdictNoQUIC,
			"путь до адреса живой (согласование версии отвечает), но на Initial не отвечают "+
				"ни с нашим именем, ни с нейтральным: похоже, хост не обслуживает HTTP/3")
	}

	// ШАГ 2. ПРЯМОЙ ЗОНД. Настоящее имя, обычная монолитная датаграмма.
	direct := run("зонд:имя как есть", func(int) probeSpec {
		return buildInitial(host, V1, 1200, 0)
	}, probeTimeout)
	switch {
	case direct.NotBuilt > 0:
		return finish(VerdictFlaky,
			"зонд с этим именем не собрался — мерить нечем, вывода нет")
	case direct.Answered == opt.Repeats:
		return finish(VerdictClear, "Initial с этим именем проходит как есть")
	case direct.Answered > 0:
		return finish(VerdictFlaky,
			fmt.Sprintf("ответов %d из %d: измерение не воспроизводится, вердикт выносить нельзя",
				direct.Answered, opt.Repeats))
	}

	// Дальше известно: контроль отвечает, наше имя — нет. Значит решение
	// принимается по содержимому, и есть смысл спрашивать коробку, ЧТО именно
	// она разбирает.
	res.Verdict = VerdictContent

	// ШАГ 3. ОСТАТОЧНАЯ БЛОКИРОВКА — и она проверяется ИМЕННО ЗДЕСЬ, сразу
	// после срабатывания, а не в конце.
	//
	// Если коробка после срабатывания глушит всё подряд на ту же тройку, то
	// любой следующий вопрос получит тишину независимо от своего содержания, и
	// замер выдал бы «ничего не помогает» там, где мерил собственный след.
	// Проверка дешёвая: повторяем ТУ ЖЕ нейтральную нагрузку, которая только
	// что отвечала. Замолчала — коробка помнит, и дальше каждому вопросу нужен
	// свежий адрес.
	//
	// Исходный порт при этом берётся новый (эфемерный). Поэтому один зонд даёт
	// сразу два факта: есть ли память вообще и входит ли в её ключ исходный
	// порт. У GFW ключ — тройка без исходного порта.
	residual := run("остаточная блокировка: контроль после срабатывания", func(int) probeSpec {
		return buildInitial(neutralName(), V1, 1200, 0)
	}, probeTimeout)
	hasResidual := residual.Answered == 0
	res.Props.ResidualBlocking = boolp(hasResidual)
	if hasResidual {
		res.Props.ResidualIgnoresSrcPort = boolp(true)
	}

	pool := &addrPool{pinned: addr, fresh: hasResidual, spare: addrs[1:]}

	// Сперва боевой арсенал: фальшивки, повторы, TTL, фрагментация. Именно из
	// него получается строка, которую человек может вставить и получить эффект.
	// Расстояние до сервера берём из TTL входящего пакета контроля — на нём
	// строится окно для укороченной фальшивки.
	res.Props.ServerTTLIn = base.TTLIn
	askArms(ctx, pool, host, opt, probeTimeout, &res)

	// Потом вопросы про устройство коробки. Они дают находки, а не строки, и
	// потому идут вторыми: при остаточной блокировке адреса кончатся, и терять
	// надо менее ценное.
	askProperties(ctx, pool, host, opt, probeTimeout, &res)
	compose(&res)

	res.Duration = time.Since(started).Round(time.Millisecond).String()
	if res.Reason == "" {
		res.Reason = "имя режут по содержимому: контроль на тот же адрес отвечает, это имя — нет"
	}
	return res
}

// firstTimeout — потолок для самого первого зонда, когда RTT ещё неизвестен.
// isLocal — адрес, до которого провайдерская коробка физически не участвует.
func isLocal(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() ||
		ip.IsUnspecified() || inCGNAT(ip)
}

// inCGNAT — 100.64.0.0/10 приватным в смысле RFC 1918 не считается, но за ним
// точно так же стоит чужой NAT, а не провайдерская коробка.
func inCGNAT(ip net.IP) bool {
	v4 := ip.To4()
	return v4 != nil && v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
}

func firstTimeout(opt Options) time.Duration {
	if opt.Timeout > 0 {
		return opt.Timeout
	}
	return 3 * time.Second
}

// deriveTimeout выводит потолок ожидания из измеренного RTT.
//
// Пол в 1,5 с не запас «на всякий случай»: сервер повторяет свой Initial по
// таймеру PTO, а начальный PTO по RFC 9002 §6.2 около секунды. Потолок ниже
// съедал бы законные повторы и считал их блокировкой.
func deriveTimeout(rttMS int64) time.Duration {
	t := time.Duration(rttMS*3) * time.Millisecond
	if t < 1500*time.Millisecond {
		t = 1500 * time.Millisecond
	}
	if t > 6*time.Second {
		t = 6 * time.Second
	}
	return t
}

// probeSpec — всё, что нужно, чтобы отправить один зонд и понять ответ.
//
// Версия здесь не для порядка: ответ раскрывается ключами, а вывод ключей
// зависит от версии. Спутать их — значит объявить живой ответ «чужим пакетом».
type probeSpec struct {
	pkts [][]byte
	// ttls — TTL для каждой датаграммы отдельно, 0 значит «как обычно».
	//
	// Нужно ради фальшивки, которая обязана умереть между коробкой и сервером:
	// коробка её увидит и учтёт, сервер — нет. Это и есть ip_ttl/ip_autottl из
	// боевых плеч. Ставится опцией сокета, сырой сокет для этого не нужен.
	ttls    []int
	dcid    []byte
	ver     Version
	srcPort int // 0 — любой
	// frag — если задан, датаграммы уходят сырым сокетом, разрезанными на
	// IP-фрагменты по этому плану.
	frag *fragPlan
}

// buildInitial — обычный клиентский Initial с указанным именем.
func buildInitial(sni string, v Version, size, srcPort int) probeSpec {
	dcid, scid := randomID(8), randomID(8)
	hello, err := ClientHello(sni, scid)
	if err != nil {
		return probeSpec{}
	}
	return marshalSpec(Initial{
		Version: v, DCID: dcid, SCID: scid,
		PacketNumber: 0, PNLen: 4,
		Crypto:      []CryptoFrame{{Offset: 0, Data: hello}},
		DatagramLen: size,
	}, dcid, v, srcPort)
}

// fragPlan — как резать датаграмму на IP-фрагменты.
//
// Поля и их смысл взяты ИЗ НАШЕГО ЖЕ КОДА (files/lua/z2k-modern-core.lua,
// z2k_ipfrag3_params), а не придуманы: смещения считаются от начала
// UDP-заголовка, всё выравнивается по восьми байтам, перекрытие сдвигает НАЧАЛО
// следующего фрагмента назад. Если бы я взял свою трактовку, зонд мерил бы не
// то плечо, которое потом уедет в конфиг.
type fragPlan struct {
	pos1 int // первый разрез; для UDP боевое умолчание 8 — ровно UDP-заголовок
	pos2 int // второй разрез (только для трёх фрагментов)
	ov12 int // перекрытие первого и второго
	ov23 int // перекрытие второго и третьего
	// three — три фрагмента (z2k_ipfrag3) вместо двух (штатный ipfrag).
	three bool
	// disorder — слать с конца. Коробка, собирающая по мере поступления,
	// увидит хвост раньше головы.
	disorder bool
}

func marshalSpec(p Initial, dcid []byte, v Version, srcPort int) probeSpec {
	pkt, err := p.Marshal()
	if err != nil {
		return probeSpec{}
	}
	return probeSpec{pkts: [][]byte{pkt}, dcid: dcid, ver: v, srcPort: srcPort}
}

// resolveAll возвращает ВСЕ адреса имени, а не первый.
//
// Запасные адреса — это не роскошь: при остаточной блокировке каждый вопрос к
// коробке требует чистого следа, то есть своей тройки (srcIP, dstIP, dstPort).
// Менять исходный порт бесполезно — он в ключ не входит; менять порт назначения
// нельзя — там нет сервера. Остаётся менять адрес.
func resolveAll(ctx context.Context, host string, opt Options) ([]*net.UDPAddr, error) {
	if opt.Addr != "" {
		a, err := net.ResolveUDPAddr("udp4", opt.Addr)
		if err != nil {
			return nil, fmt.Errorf("адрес %q не разбирается: %v", opt.Addr, err)
		}
		return []*net.UDPAddr{a}, nil
	}
	if ip := net.ParseIP(host); ip != nil {
		a := &net.UDPAddr{IP: ip, Port: opt.Port}
		if !opt.AllowLoopback && a.IP.IsLoopback() {
			return nil, errors.New("адрес петлевой; для стенда нужен явный флаг")
		}
		return []*net.UDPAddr{a}, nil
	}
	var r net.Resolver
	ips, err := r.LookupIP(ctx, "ip4", host)
	if err != nil {
		return nil, fmt.Errorf("имя не разрешается: %v", err)
	}
	if len(ips) == 0 {
		return nil, errors.New("у имени нет адресов IPv4")
	}
	// Порядок у резолвера случаен, а замеры должны быть сравнимы: разница
	// «прошло/не прошло» обязана быть разницей зондов, а не маршрутов.
	sort.Slice(ips, func(i, j int) bool { return ips[i].String() < ips[j].String() })
	out := make([]*net.UDPAddr, 0, len(ips))
	for _, ip := range ips {
		a := &net.UDPAddr{IP: ip, Port: opt.Port}
		if !opt.AllowLoopback && a.IP.IsLoopback() {
			continue
		}
		out = append(out, a)
	}
	if len(out) == 0 {
		return nil, errors.New("все адреса имени петлевые")
	}
	return out, nil
}

// measure гоняет один зонд Repeats раз и считает ответы.
//
// Каждый повтор — СВОЙ сокет и СВОЙ идентификатор соединения. Это не
// перестраховка: коробка может держать состояние по пятёрке, и повтор в той же
// пятёрке мерил бы уже её память о предыдущем зонде, а не сам зонд.
func measure(ctx context.Context, addr *net.UDPAddr, opt Options,
	mk func(attempt int) probeSpec, timeout time.Duration) Step {

	var (
		mu       sync.Mutex
		answered int
		refused  int
		notBuilt int
		ttlIn    int
		best     int64
		note     string
		wg       sync.WaitGroup
	)
	sem := make(chan struct{}, opt.Parallel)
	for i := 0; i < opt.Repeats; i++ {
		wg.Add(1)
		go func(attempt int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			spec := mk(attempt)
			if len(spec.pkts) == 0 {
				mu.Lock()
				notBuilt++
				note = "зонд не собрался"
				mu.Unlock()
				return
			}
			r := exchange(ctx, addr, spec, timeout)
			mu.Lock()
			defer mu.Unlock()
			switch {
			case r.ok:
				answered++
				if best == 0 || r.ms < best {
					best = r.ms
				}
				if r.ttlIn > 0 && ttlIn == 0 {
					ttlIn = r.ttlIn
				}
			case r.refused:
				refused++
			case r.err != nil:
				// Не отправили — значит и не померили. Считать это «приём не
				// помог» нельзя: живой пример — зонд с низким исходным портом,
				// который на маке не биндится без прав root.
				notBuilt++
				if note == "" {
					note = r.err.Error()
				}
			}
		}(i)
	}
	wg.Wait()
	return Step{Sent: opt.Repeats, Answered: answered, Refused: refused,
		NotBuilt: notBuilt, TTLIn: ttlIn, MS: best, Note: note}
}

// exchange шлёт датаграммы и ждёт ответа, который РАСКРЫВАЕТСЯ нашими ключами.
// exchangeResult — исход одного обмена.
type exchangeResult struct {
	ms      int64
	ok      bool
	refused bool // ICMP «порт недоступен» — доказательство доставки
	ttlIn   int  // TTL входящего пакета: по нему считается расстояние до сервера
	err     error
}

// exchange шлёт датаграммы и ждёт ответа, который РАСКРЫВАЕТСЯ нашими ключами.
func exchange(ctx context.Context, addr *net.UDPAddr, spec probeSpec,
	timeout time.Duration) exchangeResult {

	if spec.frag != nil {
		return exchangeFragmented(ctx, addr, spec, timeout)
	}

	d := net.Dialer{Control: markControl}
	if spec.srcPort > 0 {
		d.LocalAddr = &net.UDPAddr{Port: spec.srcPort}
	}
	c, err := d.DialContext(ctx, "udp4", addr.String())
	if err != nil {
		return exchangeResult{err: err}
	}
	defer c.Close()
	conn, ok := c.(*net.UDPConn)
	if !ok {
		return exchangeResult{err: errors.New("quicprobe: сокет не UDP")}
	}

	// Просим ядро сообщать TTL входящих пакетов. Он нужен, чтобы посчитать
	// расстояние до сервера: рабочее окно для фальшивки с укороченным TTL
	// лежит между коробкой и сервером, и верхнюю границу даёт только замер.
	pc := ipv4.NewPacketConn(conn)
	wantTTL := pc.SetControlMessage(ipv4.FlagTTL, true) == nil

	start := time.Now()
	for i, p := range spec.pkts {
		if i < len(spec.ttls) && spec.ttls[i] > 0 {
			if err := pc.SetTTL(spec.ttls[i]); err != nil {
				return exchangeResult{err: err}
			}
		} else if i > 0 && i-1 < len(spec.ttls) && spec.ttls[i-1] > 0 {
			// Вернуть обычный TTL после укороченной фальшивки: настоящий пакет
			// обязан дойти до сервера, иначе мы померим собственную диверсию.
			if err := pc.SetTTL(64); err != nil {
				return exchangeResult{err: err}
			}
		}
		if _, err := conn.Write(p); err != nil {
			return exchangeResult{refused: errors.Is(err, syscall.ECONNREFUSED), err: err}
		}
	}

	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	buf := make([]byte, 2048)
	for {
		var (
			n    int
			cm   *ipv4.ControlMessage
			rerr error
		)
		if wantTTL {
			n, cm, _, rerr = pc.ReadFrom(buf)
		} else {
			n, rerr = conn.Read(buf)
		}
		if rerr != nil {
			// Тишина — не ошибка, это исход измерения. А отказ порта —
			// доказательство доставки, и его надо отличать.
			return exchangeResult{refused: errors.Is(rerr, syscall.ECONNREFUSED)}
		}
		ttl := 0
		if cm != nil {
			ttl = cm.TTL
		}
		resp, perr := Parse(buf[:n], spec.dcid, spec.ver)
		if perr == nil && resp.Answered() {
			return exchangeResult{ms: time.Since(start).Milliseconds(), ok: true, ttlIn: ttl}
		}
		// Пакет прилетел, но нашими ключами не раскрылся. Ответом не считаем и
		// ждём дальше: настоящий ответ может прийти следом.
		if time.Since(start) > timeout {
			return exchangeResult{}
		}
	}
}

func boolp(v bool) *bool { return &v }
