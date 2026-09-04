package quicprobe

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"strings"
	"time"
)

// ВОПРОСЫ К КОРОБКЕ.
//
// Каждый вопрос — это ОДНО изменённое свойство записи одного и того же
// заблокированного имени. Появился ответ — свойство существенно, коробка на
// него опирается. Ответа нет — свойство несущественно ЛИБО зонд не доехал;
// поэтому одиночная тишина выводом не становится никогда, вывод делается
// только из пары «контроль отвечает, зонд молчит».
//
// Порядок вопросов не косметика. Если у коробки есть остаточная блокировка,
// первое же срабатывание глушит ВСЕ последующие датаграммы на ту же тройку
// (srcIP, dstIP, dstPort) — у GFW на 180 секунд. Тогда любой следующий вопрос
// получил бы тишину независимо от своего содержания, и замер выдал бы
// «ничего не помогает» там, где он мерил собственный след. Поэтому остаточная
// блокировка проверяется сразу после прямого зонда, и если она есть, каждому
// следующему вопросу выдаётся СВОЙ адрес назначения.

// addrPool раздаёт адреса вопросам.
//
// Пока остаточной блокировки нет, все вопросы идут на один адрес: так они
// сравнимы между собой, и разница «прошло/не прошло» — это разница зондов, а
// не маршрутов. Как только она обнаружена, каждому вопросу нужен свежий адрес,
// и адресов может не хватить. Что осталось незаданным — попадает в трассу:
// молчаливо сокращать охват нельзя, иначе неполный замер читается как полный.
type addrPool struct {
	spare   []*net.UDPAddr
	fresh   bool
	next    int
	pinned  *net.UDPAddr
	skipped []string
}

func (p *addrPool) take(question string) *net.UDPAddr {
	if !p.fresh {
		return p.pinned
	}
	if p.next >= len(p.spare) {
		p.skipped = append(p.skipped, question)
		return nil
	}
	a := p.spare[p.next]
	p.next++
	return a
}

// question — один вопрос к коробке.
type question struct {
	name string
	// mk получает номер попытки: повторы идут параллельно, и зонд, которому
	// нужен КОНКРЕТНЫЙ исходный порт, обязан брать разный на каждую попытку —
	// иначе три повтора дерутся за один порт и два падают с EADDRINUSE.
	mk func(sni string, attempt int) probeSpec
	// apply получает «появился ли ответ» и записывает измеренное свойство.
	apply func(p *Properties, passed bool)
	// finding — что сказать человеку, если приём сработал, а движок его не
	// умеет. Пусто — приём исполним, и его подхватит compose.
	finding string
}

// splitPoint — где резать приветствие. Режем ВНУТРИ имени, а не посередине
// буфера: если коробка ищет подстроку, разрыв именно в имени её ломает, а
// разрыв в случайном месте — нет.
func splitPoint(hello []byte, sni string) int {
	if i := bytes.Index(hello, []byte(sni)); i > 0 {
		return i + len(sni)/2
	}
	return len(hello) / 2
}

func questions(port int) []question {
	return []question{
		{
			// Коробка считает, что Initial — первый пакет потока. Если первой
			// уходит любая другая датаграмма, поток из-под разбора выпадает.
			// Настоящий QUIC-сервер мусор молча игнорирует.
			//
			// Мусор — РОВНО ТЕ БАЙТЫ, которые уйдут в строке стратегии
			// (blob=0x00000000000000000000000000000000, такие плечи в конфиге
			// уже есть). Слать случайные байты и рекомендовать нули значило бы
			// мерить одно, а применять другое.
			name: "перед Initial мусорная датаграмма",
			mk: func(sni string, attempt int) probeSpec {
				s := buildInitial(sni, V1, 1200, 0)
				if s.pkts == nil {
					return s
				}
				s.pkts = append([][]byte{make([]byte, 16)}, s.pkts...)
				return s
			},
			apply: func(p *Properties, passed bool) { p.JunkAheadHelps = boolp(passed) },
		},
		{
			// То же, но первым идёт ВАЛИДНЫЙ Initial с разрешённым именем.
			// Отличается от мусора тем, что коробка его разберёт и, возможно,
			// зафиксирует поток как разрешённый. Ровно это делает наш fake.
			// Приманку берём С ДИСКА — тот самый файл, на который сошлётся
			// строка стратегии. Собранный на лету Initial с тем же именем был
			// бы похож, но не тот же: у него другой DCID, а из чего коробка
			// строит состояние потока, мы как раз НЕ знаем. Мерить надо теми
			// байтами, которые потом уйдут в провод.
			name: "перед Initial фальшивый с разрешённым именем",
			mk: func(sni string, attempt int) probeSpec {
				decoy := loadBlob(decoyBlobFile)
				if decoy == nil {
					return probeSpec{}
				}
				s := buildInitial(sni, V1, 1200, 0)
				if s.pkts == nil {
					return probeSpec{}
				}
				s.pkts = append([][]byte{decoy}, s.pkts...)
				return s
			},
			apply: func(p *Properties, passed bool) {
				if passed {
					p.FakeAhead = "quic_google"
				}
			},
		},
		{
			// Приветствие разложено на два кадра CRYPTO с разрывом ВНУТРИ
			// имени и в обратном порядке. Точный аналог разреза TCP-потока и
			// единственный приём, ломающий РАЗБОР, а не сигнатуру.
			name: "приветствие двумя кадрами CRYPTO",
			mk: func(sni string, attempt int) probeSpec {
				dcid, scid := randomID(8), randomID(8)
				hello, err := ClientHello(sni, scid)
				if err != nil {
					return probeSpec{}
				}
				cut := splitPoint(hello, sni)
				return marshalSpec(Initial{
					Version: V1, DCID: dcid, SCID: scid, PNLen: 4, DatagramLen: 1200,
					Crypto: []CryptoFrame{
						{Offset: uint64(cut), Data: hello[cut:]},
						{Offset: 0, Data: hello[:cut]},
					},
				}, dcid, V1, 0)
			},
			apply: func(p *Properties, passed bool) { p.SplitCryptoHelps = boolp(passed) },
			finding: "приветствие, разложенное на два кадра CRYPTO, проходит — коробка их не пересобирает. " +
				"Движок сегодня так не умеет: расшифровать Initial он может, а собрать и зашифровать обратно — нет. " +
				"Это новая функция lua-desync, а не настройка существующей.",
		},
		{
			// То же, но половины уезжают РАЗНЫМИ датаграммами, вторая первой.
			// Так шлёт Chrome с постквантовым ключом и Firefox 137 по умолчанию.
			name: "приветствие двумя датаграммами",
			mk: func(sni string, attempt int) probeSpec {
				dcid, scid := randomID(8), randomID(8)
				hello, err := ClientHello(sni, scid)
				if err != nil {
					return probeSpec{}
				}
				cut := splitPoint(hello, sni)
				tail, err1 := Initial{Version: V1, DCID: dcid, SCID: scid, PacketNumber: 1, PNLen: 4,
					DatagramLen: 1200, Crypto: []CryptoFrame{{Offset: uint64(cut), Data: hello[cut:]}}}.Marshal()
				head, err2 := Initial{Version: V1, DCID: dcid, SCID: scid, PacketNumber: 0, PNLen: 4,
					DatagramLen: 1200, Crypto: []CryptoFrame{{Offset: 0, Data: hello[:cut]}}}.Marshal()
				if err1 != nil || err2 != nil {
					return probeSpec{}
				}
				return probeSpec{pkts: [][]byte{tail, head}, dcid: dcid, ver: V1}
			},
			apply: func(p *Properties, passed bool) { p.SplitDatagramsHelps = boolp(passed) },
			finding: "приветствие, разложенное на две датаграммы, проходит — коробка их не собирает. " +
				"Исполнить нечем по той же причине, что и предыдущий приём.",
		},
		{
			// У второй версии другая соль и другие метки вывода ключей, а ещё
			// перенумерованы типы пакетов. Коробка, зашитая на v1, такой
			// Initial не расшифрует вовсе.
			name: "тот же Initial во второй версии QUIC",
			mk: func(sni string, attempt int) probeSpec {
				return buildInitial(sni, V2, 1200, 0)
			},
			apply: func(p *Properties, passed bool) { p.VersionTwoHelps = boolp(passed) },
			finding: "Initial второй версии проходит — коробка знает только первую. " +
				"На живом пакете версию не переписать: она входит в связанные данные AEAD, " +
				"и правка ломает рукопожатие самого пользователя. Это довод для клиента, не для движка.",
		},
		{
			// Второй по старшинству бит по RFC 9000 обязан быть единицей, и
			// коробка обычно по нему отличает QUIC от прочего UDP. RFC 9287
			// разрешает его гриз.
			name: "сброшен фиксированный бит",
			mk: func(sni string, attempt int) probeSpec {
				dcid, scid := randomID(8), randomID(8)
				hello, err := ClientHello(sni, scid)
				if err != nil {
					return probeSpec{}
				}
				return marshalSpec(Initial{
					Version: V1, DCID: dcid, SCID: scid, PNLen: 4, DatagramLen: 1200,
					ClearFixedBit: true,
					Crypto:        []CryptoFrame{{Offset: 0, Data: hello}},
				}, dcid, V1, 0)
			},
			apply: func(p *Properties, passed bool) { p.ClearFixedBitHelps = boolp(passed) },
			finding: "с погашенным фиксированным битом Initial проходит. Сервер обязан такой пакет принять " +
				"только если сам объявил grease_quic_bit, поэтому приём ненадёжен, а движок его и не умеет.",
		},
		{
			// Оптимизация отбора трафика: коробке незачем разбирать ответы
			// сервера, и она отбрасывает датаграммы, у которых исходный порт не
			// больше порта назначения. У GFW это подтверждено перебором пар
			// портов.
			name: "исходный порт ниже порта назначения",
			mk: func(sni string, attempt int) probeSpec {
				s := buildInitial(sni, V1, 1200, 0)
				if p := port - 1 - attempt; p > 0 {
					s.srcPort = p
				}
				return s
			},
			apply: func(p *Properties, passed bool) { p.LowSourcePortHelps = boolp(passed) },
			finding: "с исходным портом ниже порта назначения Initial проходит — коробка так экономит на разборе. " +
				"Десинком это не выражается: нужен SNAT исходного порта, отдельное правило фаервола.",
		},
		{
			// Добивка длины настоящей датаграммы. Единственный из
			// «исполнимых» приёмов, который правит сам пакет, а не добавляет
			// соседей: по RFC 9000 §12.2 приёмник разбирает первый пакет по его
			// полю длины, а неразобранный хвост датаграммы отбрасывает.
			name: "датаграмма длиннее обычной",
			mk: func(sni string, attempt int) probeSpec {
				return buildInitial(sni, V1, 1300, 0)
			},
			apply: func(p *Properties, passed bool) {
				if passed {
					p.UDPLen = 100
				}
			},
		},
	}
}

func askProperties(ctx context.Context, pool *addrPool, host string, opt Options,
	timeout time.Duration, res *Result) {

	for _, q := range questions(opt.Port) {
		addr := pool.take(q.name)
		if addr == nil {
			res.Trace = append(res.Trace, Step{
				Name: q.name,
				Note: "не спрошено: у коробки остаточная блокировка, а свободных адресов не осталось",
			})
			continue
		}
		st := measure(ctx, addr, opt, func(attempt int) probeSpec { return q.mk(host, attempt) }, timeout)
		st.Name = q.name
		res.Probes += st.Sent - st.NotBuilt

		// Несобравшийся зонд — не измерение. Свойство остаётся «не измерено»,
		// а не «не подтвердилось»: склеить их значило бы выдать собственную
		// ошибку за факт о коробке.
		if st.NotBuilt > 0 {
			st.Note = "не измерено: нет файла блоба или зонд не собрался"
			res.Trace = append(res.Trace, st)
			continue
		}
		// Вывод только при ЕДИНОГЛАСИИ. У датаграмм одиночная потеря — норма,
		// а одиночный проход может быть и везением: коробка под нагрузкой
		// пропускает часть потоков (у GFW это измерено прямо).
		passed := st.Answered == opt.Repeats
		if st.Answered > 0 && st.Answered < opt.Repeats {
			st.Note = fmt.Sprintf("ответов %d из %d — неустойчиво, свойство не засчитано",
				st.Answered, opt.Repeats)
		}
		res.Trace = append(res.Trace, st)
		q.apply(&res.Props, passed)
		if passed && q.finding != "" {
			res.Findings = append(res.Findings, q.finding)
		}
	}
	if len(pool.skipped) > 0 {
		res.Notes = append(res.Notes, fmt.Sprintf(
			"не заданы вопросы (%s): у коробки остаточная блокировка, а у имени не хватило адресов, "+
				"чтобы задать каждый вопрос с чистого следа", strings.Join(pool.skipped, ", ")))
	}
}

// compose переводит измеренные свойства в строку, которую движок УМЕЕТ
// исполнить. Всё, что измерено, но неисполнимо, ушло в Findings и сюда не
// попадает: выдавать за готовую строку то, чего движок не сделает, — обман.
func compose(res *Result) {
	var arms []string
	p := res.Props

	// Фальшивка перед настоящим пакетом.
	switch {
	case p.FakeAhead != "":
		arm := "--lua-desync=fake:payload=quic_initial:dir=out:blob=" + p.FakeAhead
		if p.FakeRepeats > 0 {
			arm += fmt.Sprintf(":repeats=%d", p.FakeRepeats)
		} else {
			arm += ":repeats=2"
		}
		if p.FakeTTL > 0 {
			// Печатаем измеренное значение, а не ip_autottl: тот пересчитывает
			// TTL по ВХОДЯЩЕМУ пакету, а у заблокированного потока входящих
			// нет, и на живом домене он просто не заведётся. Мы расстояние
			// померили, поэтому ставим его прямо.
			arm += fmt.Sprintf(":ip_ttl=%d", p.FakeTTL)
		}
		arms = append(arms, arm)
	case p.JunkAheadHelps != nil && *p.JunkAheadHelps:
		arms = append(arms, "--lua-desync=fake:payload=quic_initial:dir=out:"+
			"blob=0x00000000000000000000000000000000:repeats=2")
	}

	// Фрагментация — только если доказано, что фрагменты на этом канале живут.
	if p.FragArm != "" && p.FragSurvives != nil && *p.FragSurvives {
		if arm := fragArmLine(p.FragArm); arm != "" {
			// Оригинал после фрагментов надо погасить, иначе коробка увидит
			// целую датаграмму и приём теряет смысл. Так же собраны боевые плечи.
			arms = append(arms, arm, "--lua-desync=drop")
		}
	}

	if p.UDPLen > 0 {
		arms = append(arms, fmt.Sprintf("--lua-desync=udplen:payload=quic_initial:dir=out:increment=%d",
			p.UDPLen))
	}
	if len(arms) == 0 {
		return
	}
	// ОТДАЁМ ТОЛЬКО ПРИЁМЫ, без фильтров порта и уровня.
	//
	// Каркас профиля дописывает панель (strategy_complete_line): она берёт его
	// из строки ТОГО ПУЛА, куда вставляют, и вместе с ним приезжают окно,
	// --payload и, главное, ротатор circular с правильным key=. Если отдать
	// строку уже с --filter-, панель решит, что человек принёс полный набор,
	// и каркас не добавит — обход останется без ротатора и без окна.
	//
	// Ровно так же устроен TCP-подбор: classify печатает один приём и ничего
	// вокруг. Расхождение между двумя половинами одного инструмента было бы
	// ловушкой для того, кто пользуется обеими.
	res.Strategy = strings.Join(arms, " ")
}

// fragArmLine переводит прошедшее плечо фрагментации в строку движка.
// Параметры те же, которыми зонд и мерил, — иначе эффект не воспроизведётся.
func fragArmLine(arm string) string {
	const head = "--lua-desync=send:payload=quic_initial:dir=out:"
	switch arm {
	case "ipfrag pos=8":
		return head + "ipfrag:ipfrag_pos_udp=8"
	case "ipfrag pos=8 обратный порядок":
		return head + "ipfrag:ipfrag_pos_udp=8:ipfrag_disorder"
	case "z2k_ipfrag3_tiny":
		return head + "ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:" +
			"ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder"
	case "z2k_ipfrag3":
		return head + "ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:" +
			"ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder"
	}
	return ""
}
