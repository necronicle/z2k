package classify

import (
	"context"
	"fmt"
)

// Свойства сперва, стратегия — из них.
//
// ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ ПРЕЖНЕГО ХОДА. Раньше свойства коробки записывались
// как побочный продукт перебора: гоняли девяносто гипотез, а из исходов задним
// числом узнавали, что коробка умеет. Порядок был обратный правильному, и
// держался он на том, что список отсортирован по замеренной частоте попаданий
// — то есть на подгонке под статистику, а не на выводе.
//
// Здесь сперва задаются ВОПРОСЫ, по одному на свойство, а стратегия
// СОБИРАЕТСЯ из ответов. Перебор остаётся, но уже запасным путём: он нужен
// там, где вектор свойств не дал рабочей сборки, а не вместо неё.
//
// Шесть вопросов вместо девяноста попыток — и каждый отвечает на что-то о
// коробке, даже когда не даёт готового обхода.

// propProbe — вопрос к коробке. Гипотеза здесь двойного назначения: если она
// проходит, она же и есть стратегия; если нет, её провал всё равно сообщает
// свойство.
type propProbe struct {
	name string
	p    poison
	// set записывает исход в вектор свойств.
	set func(pr *Properties, passed bool)
}

func propProbes() []propProbe {
	t, f := true, false
	return []propProbe{
		{"перекрытие слева", poison{name: "seqovl-1", seqovl: 1},
			func(pr *Properties, ok bool) {
				if ok {
					pr.ToleratesLeftOverlap = &f
				} else {
					pr.ToleratesLeftOverlap = &t
				}
			}},
		{"порядок сегментов", poison{name: "disorder", disorder: true},
			func(pr *Properties, ok bool) {
				if ok {
					pr.ToleratesReorder = &f
				} else {
					pr.ToleratesReorder = &t
				}
			}},
		{"контрольная сумма", poison{name: "badsum", badsum: true},
			func(pr *Properties, ok bool) {
				// Пишем ТОЛЬКО по проходу. Проход однозначен: коробка проглотила
				// фальшивку с битой суммой, значит сумму не сверяет. Промах
				// объясняется и разбором L7, и чем угодно ещё, поэтому поле
				// остаётся неизмеренным — так требует норма пакета.
				if ok {
					pr.ValidatesChecksum = &f
				}
			}},
		{"разбор протокола", poison{name: "badsum+hello", badsum: true, decoy: "hello"},
			func(pr *Properties, ok bool) {
				// Сюда доходим только после промаха зонда выше: набивку коробка
				// не взяла. Если теперь взяла ПРИВЕТСТВИЕ — значит разбирает L7,
				// а заодно доказано, что сумму она не сверяет.
				//
				// Раньше здесь стояло предусловие «ValidatesChecksum == true»,
				// и оно было тавтологией с перевёрнутым знаком: true туда
				// попадал ровно из промаха предыдущего зонда, а проход ЭТОГО
				// зонда означает обратное. Из-за него отчёт всегда печатал
				// «разбирает протокол: да» рядом с ложным «сумму проверяет: да».
				if ok {
					pr.ParsesL7 = &t
					pr.ValidatesChecksum = &f
				}
			}},
		{"повтор как ретрансмит", poison{name: "badsum-x2-g20", badsum: true, repeats: 2, gapMS: 20},
			func(pr *Properties, ok bool) {
				if ok {
					pr.CountsDuplicates = &t
				}
			}},
		{"данные в SYN", poison{name: "syndata", synData: true},
			func(pr *Properties, ok bool) {
				if ok {
					pr.InspectsSYN = &f
				}
			}},
	}
}

// composeFromProps строит кандидатов ИЗ ВЕКТОРА, а не берёт из списка.
//
// Правила размещения взяты из дампов боевых плеч, а не из головы: фальшивка
// идёт отдельной посылкой ПЕРЕД перекрытием, приманкой служит целое
// приветствие, а не огрызок, и число копий имеет порог.
func composeFromProps(pr Properties, ctl []byte) []poison {
	var out []poison
	no := func(b *bool) bool { return b != nil && !*b }
	yes := func(b *bool) bool { return b != nil && *b }

	// Коробка глотает битую сумму и разбирает протокол — фальшивка обязана
	// быть правдоподобной, иначе она её просто пропустит мимо.
	// Битую сумму пробуем и когда свойство НЕ ИЗМЕРЕНО: раньше здесь стояло
	// no(...), которое при nil давало false и выключало единственный признак,
	// работающий на коробках, не сверяющих сумму.
	fakeBase := poison{badsum: !yes(pr.ValidatesChecksum)}
	if yes(pr.ParsesL7) {
		fakeBase.decoy = "hello"
	}

	// Дубликаты считаются как ретрансмиты — значит серия работает там, где
	// одиночная копия нет. Порог замерен: семь вплотную либо два с паузой.
	if yes(pr.CountsDuplicates) {
		a := fakeBase
		a.name, a.repeats, a.gapMS = "СОБРАНО: серия с паузой", 2, 20
		out = append(out, a)
		b := fakeBase
		b.name, b.repeats = "СОБРАНО: плотная серия", 7
		out = append(out, b)
	}

	// Левое перекрытие не подрезается — добавляем его к фальшивке. Длину
	// берём равной приманке: в неё ложится целое приветствие.
	if no(pr.ToleratesLeftOverlap) {
		c := fakeBase
		c.name, c.seqovlExact, c.decoy = "СОБРАНО: фальшивка + перекрытие", true, "hello"
		c.repeats = 7
		out = append(out, c)
	}

	// Порядок не держит — добавляем сбитый порядок к тому же.
	if no(pr.ToleratesReorder) {
		d := fakeBase
		d.name, d.disorder = "СОБРАНО: фальшивка + порядок", true
		d.repeats = 7
		out = append(out, d)
	}

	// Ничего одиночного не сработало — пробуем всё вместе. Это последний
	// собранный кандидат перед падением в перебор.
	if len(out) == 0 {
		e := poison{name: "СОБРАНО: всё сразу", badsum: true, decoy: "hello",
			seqovlExact: true, disorder: true, repeats: 7}
		out = append(out, e)
	}
	for i := range out {
		if out[i].decoy == "hello" {
			out[i].decoyPayload = ctl
			if out[i].seqovlExact {
				out[i].seqovl = len(ctl)
			}
		}
	}
	return out
}

// runProperties задаёт шесть вопросов и заполняет вектор. Возвращает первую
// гипотезу, которая сама по себе сработала, если такая была.
func runProperties(ctx context.Context, ip4 []byte, port uint16, tr Trigger, opt Options, res *Result) (poison, bool) {
	for _, pp := range propProbes() {
		if ctx.Err() != nil {
			break
		}
		p := pp.p
		if opt.Skip[p.name] {
			continue
		}
		if p.decoy == "hello" {
			p.decoyPayload = opt.Control.Payload
		}
		// Паузу и число копий кладём в наблюдение явно: без этого трасса
		// показывала «пауза=0мс» у зонда, который её честно выдерживает, и
		// читалась как поломка механизма (потратил на эту ложную тревогу
		// отдельный заход 2026-08-29).
		obs := Observation{Probe: "свойство:" + pp.name, DelayM: p.gapMS}
		pass := 0
		for i := 0; i < opt.Repeats; i++ {
			ok, err := probePoison(ctx, ip4, port, tr, p, opt.Timeout)
			res.Probes++
			if err == nil && ok {
				pass++
			}
		}
		obs.Pass, obs.Fail = pass, opt.Repeats-pass
		res.Trace = append(res.Trace, obs)
		got := pass == opt.Repeats
		pp.set(&res.Props, got)
		if got {
			return p, true
		}
	}
	return poison{}, false
}

// строковое имя собранного кандидата — чтобы в трассе было видно, что это
// вывод из свойств, а не очередная гипотеза из списка.
func composedName(p poison) string { return fmt.Sprintf("%s", p.name) }
