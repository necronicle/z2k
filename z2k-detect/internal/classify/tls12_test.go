package classify

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// Приветствие старого клиента обязано ОТЛИЧАТЬСЯ от основного, иначе
// перепроверка ничего не проверяет: мы бы мерили дважды одно и то же и делали
// вид, что покрыли телевизор.
func TestTLS12TriggerDiffersFromDefault(t *testing.T) {
	const sni = "rutracker.org"
	def, err := TLSTrigger(sni)
	if err != nil {
		t.Fatal(err)
	}
	old, err := TLS12Trigger(sni)
	if err != nil {
		t.Fatal(err)
	}

	if bytes.Equal(def.Payload, old.Payload) {
		t.Fatal("оба приветствия побайтно одинаковы")
	}
	if len(old.Payload) >= len(def.Payload) {
		t.Errorf("старое приветствие %d байт, новое %d — ожидалось, что старое короче "+
			"(нет постквантового ключа)", len(old.Payload), len(def.Payload))
	}
	if !bytes.Contains(old.Payload, []byte(sni)) {
		t.Error("в старом приветствии нет имени — мерить будет нечего")
	}

	// Главное отличие: старый клиент НЕ предлагает 1.3. Иначе сервер
	// договорится на 1.3, сертификат уедет в шифр, и весь смысл пропадёт.
	if offersTLS13(old.Payload) {
		t.Error("приветствие 1.2 предлагает TLS 1.3 — договорятся на 1.3, и класс блокировки не проявится")
	}
	if !offersTLS13(def.Payload) {
		t.Error("основное приветствие не предлагает TLS 1.3 — оно перестало быть похожим на браузер")
	}
}

// offersTLS13 ищет 0x0304 в расширении supported_versions (0x002b).
func offersTLS13(hello []byte) bool {
	for i := 43; i+4 < len(hello); i++ {
		if hello[i] != 0x00 || hello[i+1] != 0x2b {
			continue
		}
		extLen := int(binary.BigEndian.Uint16(hello[i+2 : i+4]))
		if i+4+extLen > len(hello) {
			return false
		}
		list := hello[i+5 : i+4+extLen]
		for j := 0; j+1 < len(list); j += 2 {
			if binary.BigEndian.Uint16(list[j:]) == 0x0304 {
				return true
			}
		}
		return false
	}
	return false
}

// Текст вердикта обязан говорить про старых клиентов во ВСЕХ трёх случаях.
// Молчание читалось бы как «покрывает» — самый дорогой вид вранья: макбук
// починен, телевизор нет, и связать одно с другим человек не сможет.
func TestNoteTLS12IsAlwaysExplicit(t *testing.T) {
	yes, no := true, false
	for _, c := range []struct {
		name  string
		state *bool
		want  string
	}{
		{"не проверяли", nil, "не проверен"},
		{"покрывает", &yes, "работает и на старом"},
		{"не покрывает", &no, "останутся без обхода"},
	} {
		res := &Result{Reason: "основа", CoversTLS12: c.state}
		noteTLS12(res)
		if !bytes.Contains([]byte(res.Reason), []byte(c.want)) {
			t.Errorf("%s: в вердикте нет «%s»: %s", c.name, c.want, res.Reason)
		}
	}
}

// Перепроверка на 1.2 не имеет права трогать свойства, измеренные на 1.3.
// sweepPoisons пишет в Result вектор свойств и RawUsable; если бы проверка шла
// по тому же Result, в отчёте оказались бы свойства коробки от СТАРОГО
// приветствия, а человек читал бы их как результат основного замера.
func TestVerifyTLS12DoesNotClobberProps(t *testing.T) {
	// Стенд: TLS-сервер, который отвечает на всё. Старое приветствие
	// пройдёт «как есть», и verifyTLS12 вернёт nil, не дойдя до отравления —
	// но трасса и счётчик зондов обязаны подняться наверх, а всё остальное
	// остаться нетронутым.
	addr := startStand(t, "", tls.VersionTLS12)
	yes := true
	res := Result{
		Verdict:   VerdictPoisonable,
		Reason:    "основа",
		Probes:    7,
		RawUsable: true,
		Props:     Properties{Reassembles: &yes},
		Path:      "свойство",
	}
	opt := respOpts()
	opt.withDefaults()
	got := verifyTLS12(context.Background(), addr, opt, &res, "anything.example", "seqovl-1")
	if got != nil {
		t.Fatalf("старое приветствие проходит — ожидался nil, получено %v", *got)
	}
	if res.Props.Reassembles == nil || !*res.Props.Reassembles {
		t.Error("вектор свойств затёрт перепроверкой")
	}
	if !res.RawUsable || res.Path != "свойство" {
		t.Errorf("RawUsable/Path затёрты: %v %q", res.RawUsable, res.Path)
	}
	if res.Probes <= 7 {
		t.Errorf("счётчик зондов не поднялся наверх: %d", res.Probes)
	}
	var tagged int
	for _, o := range res.Trace {
		if len(o.Probe) >= 6 && o.Probe[:6] == "tls12:" {
			tagged++
		}
	}
	if tagged == 0 {
		t.Error("шаги перепроверки не помечены в трассе как tls12:")
	}
}

// liftTrace помечает шаги приветствием и не дублирует уже помеченные: в
// трассе поддержки должно быть видно, на каком приветствии сделан каждый зонд.
func TestLiftTraceTagsSteps(t *testing.T) {
	dst := &Result{Probes: 2}
	src := &Result{Probes: 3, Trace: []Observation{{Probe: "как есть"}, {Probe: "tls12:разрез"}}}
	liftTrace(dst, src, "tls12:")
	if dst.Probes != 5 {
		t.Errorf("зонды не сложились: %d", dst.Probes)
	}
	if len(dst.Trace) != 2 || dst.Trace[0].Probe != "tls12:как есть" || dst.Trace[1].Probe != "tls12:разрез" {
		t.Errorf("трасса помечена неверно: %+v", dst.Trace)
	}
}

// Поиск общего приёма обязан уложиться в бюджет. Без потолка замер на
// www.instagram.com разросся до 3 м 45 с и был бы убит сторожем панели на
// 180-й секунде — человек не получил бы вообще ничего.
func TestJointSearchRespectsBudget(t *testing.T) {
	// Адрес, который молчит: каждый зонд упрётся в таймаут, то есть поиск
	// заведомо не сойдётся и обязан остановиться по бюджету.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	tr, err := TLSTrigger("blocked.example")
	if err != nil {
		t.Fatal(err)
	}
	opt := respOpts()
	opt.JointBudget = 300 * time.Millisecond
	opt.withDefaults()

	res := &Result{Verdict: VerdictPoisonable}
	start := time.Now()
	_, ok := findJointPoison(context.Background(), addr, tr, opt, res, "blocked.example", "seqovl-1")
	spent := time.Since(start)

	if ok {
		t.Error("на молчащем адресе поиск объявил находку")
	}
	// Потолок с запасом: важно, что поиск ОСТАНАВЛИВАЕТСЯ по бюджету, а не
	// перебирает всё дерево до конца.
	if spent > 15*time.Second {
		t.Errorf("поиск шёл %s при бюджете %s — потолок не действует", spent, opt.JointBudget)
	}
}

// Когда общего нет, строка обязана остаться той, что взяла современное
// приветствие: она полезнее пустоты, по TLS 1.3 ходит подавляющее большинство.
// Но про непокрытые устройства надо сказать прямо.
func TestFallbackKeepsModernStrategyAndWarns(t *testing.T) {
	no := false
	res := &Result{
		Verdict:     VerdictPoisonable,
		Reason:      "основа",
		Strategy:    "--lua-desync=multisplit:pos=1",
		CoversTLS12: &no,
	}
	noteTLS12(res)
	if res.Strategy != "--lua-desync=multisplit:pos=1" {
		t.Errorf("строка потеряна: %q", res.Strategy)
	}
	for _, want := range []string{"TLS 1.3", "большинство", "останутся без обхода"} {
		if !bytes.Contains([]byte(res.Reason), []byte(want)) {
			t.Errorf("в вердикте нет «%s»: %s", want, res.Reason)
		}
	}
}

// Список доменов старых устройств обязан ловить поддомены и НЕ ловить чужие
// имена, кончающиеся так же. Шаблон без точки на границе («*youtube.com»)
// совпал бы с notyoutube.com — такую дыру уже пришлось чинить в шелле панели.
func TestLegacyDeviceDomainBoundaries(t *testing.T) {
	for _, c := range []struct {
		name string
		want bool
	}{
		{"youtube.com", true},
		{"www.youtube.com", true},
		{"youtu.be", true},
		{"rr3---sn-x.googlevideo.com", true},
		{"i.ytimg.com", true},
		{"yt3.ggpht.com", true},
		{"YouTube.com", true},  // регистр не должен решать
		{"youtube.com.", true}, // корневая точка тоже
		{"notyoutube.com", false},
		{"evilggpht.com", false},
		{"youtube.com.evil.ru", false},
		{"rutracker.org", false},
		{"www.instagram.com", false},
		{"", false},
	} {
		if got := LegacyDeviceDomain(c.name); got != c.want {
			t.Errorf("%q: получено %v, ожидалось %v", c.name, got, c.want)
		}
	}
}

// Кросс-проверка на старом TLS не должна запускаться на обычном домене: она
// стоит минуты, а телевизоров там нет. Замер 04.09: instagram без неё — 3 с,
// с ней — 1 м 54 с.
func TestCrossCheckSkippedOnOrdinaryDomain(t *testing.T) {
	addr := startStand(t, "", tls.VersionTLS12)
	tr, err := TLSTrigger("rutracker.org")
	if err != nil {
		t.Fatal(err)
	}
	opt := respOpts()
	opt.withDefaults()
	res := &Result{Verdict: VerdictPrefix, Reason: "основа", SplitPos: 1}

	start := time.Now()
	crossCheckTLS12(context.Background(), addr, tr, opt, res, "")
	if spent := time.Since(start); spent > time.Second {
		t.Errorf("проверка шла %s на обычном домене — она обязана пропускаться", spent)
	}
	if res.CoversTLS12 != nil {
		t.Errorf("на обычном домене выставлен CoversTLS12=%v", *res.CoversTLS12)
	}
	if res.Reason != "основа" {
		t.Errorf("вердикт дописан на обычном домене: %s", res.Reason)
	}
}
