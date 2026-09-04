package classify

import (
	"fmt"
	"strings"
	"testing"
)

// ИНВАРИАНТ ЭКСПОРТА: строка обязана воспроизводить ту гипотезу, которая
// сработала.
//
// Этого теста не было, и цена отсутствия оказалась высокой: семнадцать гипотез
// семейства badsum-x{N}-g{G} печатались одной строкой, неотличимой от одиночной
// badsum, а badsum+ts и badsum+ipid теряли свой единственный признак. Замер
// отвечал «поймали badsum-x7», человек вставлял плечо с одной фальшивкой, и
// обход не вставал — при том, что инструмент «нашёл».
//
// Проверяем не текст, а свойство: измеренное поле обязано доехать до строки.

// Число копий доезжает до строки везде, где фальшивка вообще есть.
func TestRepeatsReachTheStrategy(t *testing.T) {
	var checked int
	for _, p := range poisons() {
		if p.repeats <= 1 || !p.hasFake() {
			continue
		}
		st := strategyForPoison(p)
		if st == "" {
			t.Errorf("%s: пустая строка при repeats=%d", p.name, p.repeats)
			continue
		}
		want := fmt.Sprintf("repeats=%d", p.repeats)
		if !strings.Contains(st, want) {
			t.Errorf("%s: в строке нет «%s»\n  %s", p.name, want, st)
		}
		checked++
	}
	if checked == 0 {
		t.Fatal("ни одной гипотезы с копиями — тест перестал что-либо проверять")
	}
}

// Метка времени и обнулённый идентификатор — такие же измеренные признаки.
func TestFoolingFlagsReachTheStrategy(t *testing.T) {
	for _, p := range poisons() {
		st := strategyForPoison(p)
		if st == "" {
			continue
		}
		if p.tcpTS && !strings.Contains(st, "tcp_ts") {
			t.Errorf("%s: метка времени измерена, а в строке её нет\n  %s", p.name, st)
		}
		if p.ipIDZero && !strings.Contains(st, "ip_id") {
			t.Errorf("%s: обнулённый идентификатор измерен, а в строке его нет\n  %s", p.name, st)
		}
	}
}

// Гипотезы, различающиеся ПО ПРОВОДУ, обязаны давать различающиеся строки.
//
// Пауза между копиями движком невыразима (у fake нет аргумента задержки,
// rawsend_rep шлёт копии вплотную), поэтому семейства, отличающиеся ТОЛЬКО
// паузой, схлопываться в одну строку имеют право — и только они.
func TestDistinctPoisonsGiveDistinctStrategies(t *testing.T) {
	byLine := map[string][]poison{}
	for _, p := range poisons() {
		st := strategyForPoison(p)
		if st == "" {
			continue
		}
		byLine[st] = append(byLine[st], p)
	}
	for st, group := range byLine {
		if len(group) < 2 {
			continue
		}
		base := group[0]
		for _, p := range group[1:] {
			if differsOnTheWire(base, p) {
				t.Errorf("разные по проводу гипотезы дают одну строку:\n  %s и %s\n  %s",
					base.name, p.name, st)
			}
		}
	}
}

// differsOnTheWire — отличаются ли две гипотезы чем-то, кроме паузы.
//
// Сравниваем поля поимённо: в структуре есть срез, и оператор равенства к ней
// неприменим. Заодно список полей здесь — это и есть перечень того, что обязано
// доезжать до строки; появится новое поле — тест придётся дополнить осознанно.
func differsOnTheWire(a, b poison) bool {
	// Перекрытие «по длине приманки» и перекрытие ровно в 681 байт с образцом
	// целого приветствия — на проводе одно и то же: 681 это и есть длина
	// шипованного приветствия, которым набивается перекрытие. Разные способы
	// задать одну величину не должны считаться разными приёмами.
	if a.seqovlExact != b.seqovlExact && a.decoy == "hello" && b.decoy == "hello" {
		ax, bx := a, b
		ax.seqovlExact, bx.seqovlExact = false, false
		ax.seqovl, bx.seqovl = 0, 0
		return differsOnTheWire(ax, bx)
	}
	return a.ttl != b.ttl ||
		a.badsum != b.badsum ||
		a.seqShift != b.seqShift ||
		a.md5 != b.md5 ||
		a.decoy != b.decoy ||
		a.disorder != b.disorder ||
		a.tcpTS != b.tcpTS ||
		a.ipIDZero != b.ipIDZero ||
		a.synData != b.synData ||
		a.oob != b.oob ||
		a.fakeBetween != b.fakeBetween ||
		a.repeats != b.repeats ||
		a.seqovlExact != b.seqovlExact ||
		a.seqovl != b.seqovl
}

// Именованные приёмы обязаны нести свои флаги: без них зонд шлёт обычную
// фальшивку, а трасса называет её «syndata» — и отрицательный исход читается
// как вывод о механизме, который ни разу не проверяли.
func TestNamedPrimitivesCarryTheirFlags(t *testing.T) {
	want := map[string]func(poison) bool{
		"syndata": func(p poison) bool { return p.synData },
		"oob":     func(p poison) bool { return p.oob },
	}
	seen := map[string]bool{}
	for _, p := range poisons() {
		check, ok := want[p.name]
		if !ok {
			continue
		}
		seen[p.name] = true
		if !check(p) {
			t.Errorf("гипотеза %q не несёт своего флага — зонд шлёт не то, что обещает имя", p.name)
		}
	}
	for n := range want {
		if !seen[n] {
			t.Errorf("гипотеза %q пропала из перебора", n)
		}
	}
}

// Свойство «коробка проверяет контрольную сумму» нельзя выводить из молчания.
// Промах фальшивки объясняется и разбором L7 — по тишине эти причины не
// различить, а ложное «да» отключало битую сумму у собранных кандидатов.
func TestChecksumVerdictNeverInferredFromSilence(t *testing.T) {
	for _, p := range poisons() {
		var pr Properties
		notePropsMiss(&pr, p)
		if pr.ValidatesChecksum != nil {
			t.Errorf("%s: промах выставил «проверяет сумму» = %v — вывод из тишины",
				p.name, *pr.ValidatesChecksum)
		}
	}
	// А проход badsum-зонда обязан давать «не проверяет»: коробка его съела.
	var pr Properties
	notePropsHit(&pr, poison{name: "badsum", badsum: true})
	if pr.ValidatesChecksum == nil || *pr.ValidatesChecksum {
		t.Errorf("проход badsum-зонда не дал «сумму не проверяет»: %v", pr.ValidatesChecksum)
	}
}

// Потеря паузы обязана быть названа. Движок её выразить не умеет, и молча
// отдать плотную серию вместо растянутой — значит отдать строку, которая может
// не повторить найденный эффект.
func TestGapLossIsAnnounced(t *testing.T) {
	var res Result
	noteGapLoss(&res, poison{name: "badsum-x2-g80", badsum: true, repeats: 2, gapMS: 80})
	if len(res.Notes) == 0 {
		t.Fatal("пауза потеряна молча")
	}
	if !strings.Contains(res.Notes[0], "80") {
		t.Errorf("в оговорке нет измеренной паузы: %s", res.Notes[0])
	}
	// Без паузы оговорки быть не должно — иначе она обесценится.
	var clean Result
	noteGapLoss(&clean, poison{name: "badsum-x7", badsum: true, repeats: 7})
	if len(clean.Notes) != 0 {
		t.Errorf("оговорка появилась там, где паузы не было: %v", clean.Notes)
	}
}
