package quicprobe

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// ВОПРОСЫ ПРО БОЕВОЙ АРСЕНАЛ.
//
// Отдельно от questions.go намеренно. Там — вопросы про УСТРОЙСТВО коробки:
// собирает ли она кадры, разбирает ли вторую версию, смотрит ли на порт. Ответы
// на них ценны сами по себе, но исполнить их движок по большей части не может.
//
// Здесь — ровно то, чем z2k по QUIC работает СЕГОДНЯ: фальшивка с шипованным
// блобом, число её копий, укороченный TTL и IP-фрагментация. Каждый прошедший
// зонд отсюда превращается в строку, которую можно вставить и получить эффект.
// Без этой половины замер отвечал бы «ничего не помогает» ровно там, где помогло
// бы штатное плечо, — и это была бы не находка, а дыра в вопроснике.

// blobs — фальшивки в том порядке, в каком их стоит пробовать.
//
// Имена — как они зарегистрированы в движке (S99zapret2.new), а не как в
// апстриме: строка со «своим» именем блоба просто не загрузится.
var blobs = []struct {
	name string
	file string // пусто — блоб не файловый, собирается ниже
}{
	{"quic5", "quic_5.bin"},
	{"quic_google", "quic_initial_www_google_com.bin"},
	{"quic_rutracker", "quic_initial_rutracker_org.bin"},
	{"fake_default_quic", ""},
	{"0x00000000000000000000000000000000", ""},
}

// blobBytes отдаёт содержимое фальшивки.
//
// fake_default_quic живёт не файлом, а внутри движка: 0x40 и дальше нули. По
// его же детектору протокола это НЕ QUIC Initial (тот требует старших битов
// 0xC0), то есть с точки зрения коробки это просто мусор нужного размера —
// поэтому он и стоит рядом с шестнадцатью нулями.
func blobBytes(name, file string) []byte {
	switch name {
	case "fake_default_quic":
		b := make([]byte, 620)
		b[0] = 0x40
		return b
	case "0x00000000000000000000000000000000":
		return make([]byte, 16)
	}
	return loadBlob(file)
}

// askArms задаёт вопросы про исполнимые приёмы и пишет то, что прошло.
//
// Порядок внутри не случаен: сперва одиночная фальшивка каждым блобом, потом
// повторы для того блоба, который показал себя лучше, потом укороченный TTL, и
// только в конце фрагментация — она дороже всех и требует сырого сокета.
func askArms(ctx context.Context, pool *addrPool, host string, opt Options,
	timeout time.Duration, res *Result) {

	// ask возвращает ДВА признака: прошёл ли приём и был ли вопрос вообще
	// задан. Склеивать их нельзя: «не измерено» и «не помогло» — разные вещи,
	// и на фрагментации разница смертельная. Первый прогон на маке выдал
	// «IP-фрагменты на канале НЕ доходят», хотя сырых сокетов там просто нет и
	// ни один фрагмент не отправлялся.
	ask := func(name string, mk func(int) probeSpec) (passed, measured bool) {
		addr := pool.take(name)
		if addr == nil {
			res.Trace = append(res.Trace, Step{Name: name,
				Note: "не спрошено: у коробки остаточная блокировка, а свободных адресов не осталось"})
			return false, false
		}
		st := measure(ctx, addr, opt, mk, timeout)
		st.Name = name
		res.Probes += st.Sent - st.NotBuilt
		if st.NotBuilt > 0 {
			if st.Note == "" {
				st.Note = "не измерено"
			} else {
				st.Note = "не измерено: " + st.Note
			}
			res.Trace = append(res.Trace, st)
			return false, false
		}
		if st.Answered > 0 && st.Answered < opt.Repeats {
			st.Note = fmt.Sprintf("ответов %d из %d — неустойчиво, приём не засчитан",
				st.Answered, opt.Repeats)
		}
		res.Trace = append(res.Trace, st)
		return st.Answered == opt.Repeats, true
	}

	// 1. ФАЛЬШИВКА ПЕРЕД НАСТОЯЩИМ ПАКЕТОМ, по одной копии каждым блобом.
	for _, b := range blobs {
		body := blobBytes(b.name, b.file)
		if body == nil {
			res.Trace = append(res.Trace, Step{Name: "фальшивка " + b.name,
				Note: "не измерено: нет файла блоба (запуск не на роутере)"})
			continue
		}
		if ok, _ := ask("фальшивка "+b.name, func(int) probeSpec {
			s := buildInitial(host, V1, 1200, 0)
			if s.pkts == nil {
				return probeSpec{}
			}
			s.pkts = append([][]byte{body}, s.pkts...)
			return s
		}); ok {
			res.Props.FakeAhead = b.name
			break
		}
	}

	// 2. ПОВТОРЫ. Отдельная ось: одна копия могла потеряться, а могла и не
	// хватить коробке. Если блоб уже нашёлся — уточняем его же; если нет,
	// пробуем два самых ходовых, вдруг дело было именно в числе копий.
	repeatCandidates := []string{res.Props.FakeAhead}
	if res.Props.FakeAhead == "" {
		repeatCandidates = []string{"quic5", "fake_default_quic"}
	}
	for _, name := range repeatCandidates {
		if res.Props.FakeRepeats > 0 {
			break
		}
		var file string
		for _, b := range blobs {
			if b.name == name {
				file = b.file
			}
		}
		body := blobBytes(name, file)
		if body == nil {
			continue
		}
		for _, n := range []int{6, 11} {
			if ok, _ := ask(fmt.Sprintf("фальшивка %s ×%d", name, n), func(int) probeSpec {
				s := buildInitial(host, V1, 1200, 0)
				if s.pkts == nil {
					return probeSpec{}
				}
				pre := make([][]byte, 0, n+1)
				for i := 0; i < n; i++ {
					pre = append(pre, body)
				}
				s.pkts = append(pre, s.pkts...)
				return s
			}); ok {
				res.Props.FakeAhead, res.Props.FakeRepeats = name, n
				break
			}
		}
	}

	// 3. УКОРОЧЕННЫЙ TTL у фальшивки — это ip_ttl/ip_autottl из боевых плеч.
	// Фальшивка обязана умереть между коробкой и сервером: коробка её учтёт,
	// сервер не увидит.
	//
	// ЗДЕСЬ РАЗВЁРТКА, А НЕ ВЫЧИСЛЕННОЕ ЧИСЛО, и это не перестраховка. Сначала
	// расстояние выводилось из TTL входящего пакета, но замер 04.09 показал,
	// что верить ему нельзя: у одного и того же адреса ICMP отдал TTL 56, а
	// ответ на QUIC — 86; у Google 107 против 60. Отвечают разные узлы, и
	// «расстояние» из одного наблюдения оказывается выдуманным числом. Ставить
	// такое в боевую строку — ровно тот случай, на котором горели раньше.
	//
	// Поэтому перебираем несколько правдоподобных расстояний до коробки
	// провайдера и берём то, которое ПРОШЛО. Наблюдённый TTL при этом остаётся
	// в выводе как сырой факт, без интерпретации.
	if res.Props.FakeTTL == 0 {
		// Порядок выбора фальшивки: та, что уже показала себя; иначе ходовой
		// quic5; иначе fake_default_quic — он собирается на месте и есть
		// всегда, поэтому развёртка не пропадает молча там, где файлов нет.
		name, body := pickDecoy(res.Props.FakeAhead)
		if body == nil {
			res.Trace = append(res.Trace, Step{Name: "фальшивка с укороченным TTL",
				Note: "не измерено: нет ни одной доступной фальшивки"})
		} else {
			for _, ttl := range []int{3, 5, 8, 12} {
				if ok, _ := ask(fmt.Sprintf("фальшивка %s с TTL %d", name, ttl),
					func(int) probeSpec {
						s := buildInitial(host, V1, 1200, 0)
						if s.pkts == nil {
							return probeSpec{}
						}
						s.pkts = append([][]byte{body}, s.pkts...)
						s.ttls = []int{ttl, 0}
						return s
					}); ok {
					res.Props.FakeAhead, res.Props.FakeTTL = name, ttl
					break
				}
			}
		}
	}

	// 4. ФРАГМЕНТАЦИЯ. Сперва ВЫЖИВАЕМОСТЬ — на заведомо отвечающем имени.
	//
	// Это не осторожность, а условие корректности. Если фрагменты режет CGNAT
	// или сама коробка, «не помогло» будет означать «приём убивает трафик», а
	// не «коробка собирает». Выдать такое плечо человеку — тихо сломать ему
	// сеть, и он даже не свяжет одно с другим.
	survived, measured := ask("фрагменты доходят вообще (контрольное имя)", func(int) probeSpec {
		s := buildInitial(neutralName(), V1, 1200, 0)
		if s.pkts == nil {
			return probeSpec{}
		}
		s.frag = &fragPlan{pos1: 8}
		return s
	})
	if !measured {
		// Не отправляли ни одного фрагмента — значит и сказать про них нечего.
		// Свойство остаётся неизмеренным, семейство не оговаривается.
		return
	}
	res.Props.FragSurvives = boolp(survived)
	if !survived {
		res.Notes = append(res.Notes,
			"фрагментированная датаграмма не дошла даже с заведомо рабочим именем — "+
				"на этом канале IP-фрагменты не живут. Семейство ipfrag не проверялось дальше "+
				"и предлагать его нельзя: это не обход, а потеря трафика")
		return
	}

	for _, arm := range []struct {
		name string
		plan fragPlan
	}{
		{"ipfrag pos=8", fragPlan{pos1: 8}},
		{"ipfrag pos=8 обратный порядок", fragPlan{pos1: 8, disorder: true}},
		{"z2k_ipfrag3_tiny", fragPlan{three: true, pos1: 8, pos2: 32, ov12: 8, ov23: 8, disorder: true}},
		{"z2k_ipfrag3", fragPlan{three: true, pos1: 16, pos2: 48, ov12: 8, ov23: 8, disorder: true}},
	} {
		plan := arm.plan
		if ok, _ := ask("фрагментация: "+arm.name, func(int) probeSpec {
			s := buildInitial(host, V1, 1200, 0)
			if s.pkts == nil {
				return probeSpec{}
			}
			s.frag = &plan
			return s
		}); ok {
			res.Props.FragArm = arm.name
			break
		}
	}
}

// pickDecoy выбирает фальшивку и её содержимое.
//
// fake_default_quic стоит последним намеренно: он не файловый, собирается на
// месте, поэтому доступен всегда — и развёртка по TTL не выпадает молча там,
// где дерева установки нет.
func pickDecoy(preferred string) (string, []byte) {
	order := []string{preferred, "quic5", "fake_default_quic"}
	for _, name := range order {
		if name == "" {
			continue
		}
		var file string
		for _, b := range blobs {
			if b.name == name {
				file = b.file
			}
		}
		if body := blobBytes(name, file); body != nil {
			return name, body
		}
	}
	return "", nil
}

// БЛОБЫ НА ДИСКЕ. Зонд обязан слать те же байты, что уйдут в строке стратегии,
// иначе он меряет одно, а рекомендация делает другое — и найденный эффект не
// воспроизведётся.
//
// Файл берётся из дерева установки. Нет файла (запуск не на роутере) — вопрос
// не задаётся вовсе: собрать «похожий» Initial и выдать результат за измерение
// шипованного блоба было бы хуже, чем промолчать.
var blobDir = "/opt/zapret2/files/fake"

const decoyBlobFile = "quic_initial_www_google_com.bin"

func loadBlob(name string) []byte {
	if name == "" {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(blobDir, name))
	if err != nil || len(b) < 64 {
		return nil
	}
	return b
}
