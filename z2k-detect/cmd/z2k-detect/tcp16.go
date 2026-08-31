package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/tcp16"
)

// tcp16Cmd — проба на блокировку по объёму соединения.
//
// Два режима, и это принципиально разные вопросы:
//
//	без -scan   есть ли этот блок на линии (и в каких AS);
//	с  -scan    какое имя из белого списка провайдер пропускает.
//
// Оба идут по КУРИРУЕМЫМ мишеням, а не по трафику человека: наблюдение за
// чужим потоком отвечает на вопрос «этот хост сейчас режут?» и ошибается, а
// проба спрашивает про линию и мерит контролируемым объёмом.
func tcp16Cmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("tcp16", flag.ExitOnError)
	targets := fs.String("targets", "/opt/zapret2/lists/tcp16_targets.txt", "файл мишеней")
	asn := fs.String("asn", "", "только эта AS (иначе все)")
	confirmed := fs.Bool("confirmed", false, "только AS, подтверждённые многими сообщениями")
	limit := fs.Int("limit", 0, "не больше N мишеней (0 — все)")
	scan := fs.String("scan", "", "файл имён-кандидатов: искать проходящее имя")
	sni := fs.String("sni", "", "проверить одно конкретное имя")
	par := fs.Int("parallel", 4, "сколько проб разом")
	asnOut := fs.String("asn-out", "", "куда выписать AS, где блок найден (по одной в строке)")
	first := fs.Bool("first", true, "при -scan остановиться на первом подошедшем имени")
	perASN := fs.Bool("per-asn", false, "искать своё имя для КАЖДОЙ сети с блоком")
	batch := fs.Int("batch", 5, "сколько имён проверять разом внутри одной сети")
	sniOut := fs.String("sni-out", "", "куда выписать карту «сеть -> имя»")
	_ = fs.Parse(rest)

	tg, err := loadTargets(*targets, *asn, *confirmed, *limit)
	if err != nil {
		fatal("%v", err)
	}
	if len(tg) == 0 {
		fatal("мишеней не осталось после фильтров")
	}

	if *scan != "" {
		names, err := loadNames(*scan)
		if err != nil {
			fatal("%v", err)
		}
		if *perASN {
			scanPerASN(ctx, tg, names, *par, *batch, *sniOut)
		} else {
			scanNames(ctx, tg, names, *par, *first)
		}
		return
	}
	probeLine(ctx, tg, *sni, *par, *asnOut)
}

// probeLine отвечает на вопрос «есть ли блок на линии» по каждой AS отдельно.
func probeLine(ctx context.Context, tg []tcp16.Target, sni string, par int, asnOut string) {
	res := runAll(ctx, tg, sni, par)

	type agg struct{ detected, alive, total int }
	byASN := map[string]*agg{}
	for _, r := range res {
		a := byASN[r.Target.ASN]
		if a == nil {
			a = &agg{}
			byASN[r.Target.ASN] = a
		}
		a.total++
		if r.Alive {
			a.alive++
		}
		if r.Detected {
			a.detected++
		}
	}
	keys := make([]string, 0, len(byASN))
	for k := range byASN {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	// Список AS с блоком нужен рантайму: имя из белого списка ставится только
	// тем адресам, что принадлежат этим AS. Без него мы ставим его всему пулу
	// подряд — замер 30.08.2026: linode, cdn77, aws и scaleway доезжают целиком
	// и без имени, то есть платят за него зря.
	var detectedASN []string

	anyDetected, anyAlive := 0, 0
	for _, k := range keys {
		a := byASN[k]
		if a.detected > 0 {
			detectedASN = append(detectedASN, k)
		}
		anyDetected += a.detected
		anyAlive += a.alive
		mark := "—"
		if a.detected > 0 {
			mark = "БЛОК"
		} else if a.alive > 0 {
			mark = "чисто"
		}
		fmt.Printf("AS%-8s %-6s  мишеней %2d, ответили %2d, блок на %d\n", k, mark, a.total, a.alive, a.detected)
	}
	if asnOut != "" {
		var sb strings.Builder
		sb.WriteString("# AS, где проба нашла блок по объёму. Пересобирается пробой.\n")
		for _, k := range detectedASN {
			sb.WriteString(k)
			sb.WriteString("\n")
		}
		if err := os.WriteFile(asnOut, []byte(sb.String()), 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "не смог записать %s: %v\n", asnOut, err)
		}
	}

	fmt.Println()
	switch {
	case anyAlive == 0:
		fmt.Println("ВЕРДИКТ: мишени не отвечают вовсе — линия или список мишеней негодны, судить не по чему")
		os.Exit(3)
	case anyDetected > 0:
		fmt.Printf("ВЕРДИКТ: блок по объёму ЕСТЬ (сработал на %d мишенях из %d ответивших)\n", anyDetected, anyAlive)
		os.Exit(1)
	default:
		fmt.Printf("ВЕРДИКТ: блока по объёму НЕТ (%d мишеней ответили, ни одна не оборвалась)\n", anyAlive)
	}
}

// scanPerASN ищет СВОЁ имя для КАЖДОЙ сети, где нашёлся блок.
//
// Одного имени на всех не бывает — замер 30.08.2026 на линии владельца:
// hcaptcha.com бьёт двадцать AS, но НЕ Hetzner; Hetzner, DigitalOcean и OVH
// берёт 300.ya.ru; Melbicom — ad.adriver.ru; семь AS не берёт ничего.
//
// Мишени порта 80 в подборе не участвуют: там нет TLS, имя подставлять некуда,
// и требовать от них «пройти» — значит не найти имя никогда.
func scanPerASN(ctx context.Context, tg []tcp16.Target, names []string, par, sniBatch int, out string) {
	if sniBatch < 1 {
		sniBatch = 1
	}
	byASN := map[string][]tcp16.Target{}
	for _, t := range tg {
		if t.Port != 443 {
			continue
		}
		byASN[t.ASN] = append(byASN[t.ASN], t)
	}
	if len(byASN) == 0 {
		fatal("нет мишеней с портом 443")
	}

	keys := make([]string, 0, len(byASN))
	for k := range byASN {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	type found struct {
		asn, name string
		tried     int
	}
	results := make([]found, len(keys))
	// Общий потолок одновременных проб на весь прогон. Ограничивать только
	// число сетей мало: внутри каждой идёт ещё батч, и суммарная нагрузка
	// получается непредсказуемой. Замер 31.08.2026 на роутере: проба линии по
	// 110 мишеням при потолке 4 шла 2 м 44 с, при 50 — 15 секунд.
	gate := make(chan struct{}, par)
	probe := func(t tcp16.Target, sni string) tcp16.Result {
		gate <- struct{}{}
		defer func() { <-gate }()
		return tcp16.Probe(ctx, t, sni)
	}
	// Печатаем по мере готовности: полный прогон идёт минуты, и молчащий до
	// конца вывод не даёт понять ни что он жив, ни на чём стоит.
	var pmu sync.Mutex
	say := func(f found) {
		pmu.Lock()
		defer pmu.Unlock()
		switch {
		case f.name != "":
			fmt.Printf("AS%-8s ПОДОШЛО %-24s (кандидат %d)\n", f.asn, f.name, f.tried)
		case f.tried > 0:
			fmt.Printf("AS%-8s имя не найдено (перебрано %d)\n", f.asn, f.tried)
		default:
			fmt.Printf("AS%-8s блока нет — имя не нужно\n", f.asn)
		}
	}
	var wg sync.WaitGroup

	for i, asn := range keys {
		wg.Add(1)
		go func(i int, asn string, tgs []tcp16.Target) {
			defer wg.Done()

			// Мишень выбираем ту, на которой блок реально виден, а из
			// нескольких таких — с наименьшим RTT: перебор идёт по ней сотню
			// раз, и лишние сто миллисекунд на пробу выливаются в минуты.
			// Без проверки «блок виден» «подошло» скажет любое имя.
			var target *tcp16.Target
			var bestRTT time.Duration
			for j := range tgs {
				// Имя мишени, если оно у неё есть. Раньше здесь стояла пустая
				// строка для ВСЕХ — и мишени, отвечающие только по имени,
				// молча выпадали из замера.
				r := probe(tgs[j], tgs[j].SNI)
				if r.Alive && r.Detected && (target == nil || r.RTT < bestRTT) {
					target = &tgs[j]
					bestRTT = r.RTT
				}
			}
			if target == nil {
				results[i] = found{asn: asn, name: ""}
				say(results[i])
				return
			}

			// Кандидаты идём БАТЧАМИ. По одному это 188 × шесть секунд на
			// сеть, где не подходит ничто, — двадцать минут вместо четырёх.
			// Батч запускается целиком, из подошедших берём ПЕРВОГО ПО
			// ПОРЯДКУ В ФАЙЛЕ: порядок там осмысленный, и «какой раньше
			// ответил» его бы ломал.
			for start := 0; start < len(names); start += sniBatch {
				select {
				case <-ctx.Done():
					return
				default:
				}
				end := start + sniBatch
				if end > len(names) {
					end = len(names)
				}
				batch := names[start:end]
				okIdx := make([]bool, len(batch))
				var bwg sync.WaitGroup
				for j, name := range batch {
					bwg.Add(1)
					go func(j int, name string) {
						defer bwg.Done()
						r := probe(*target, name)
						okIdx[j] = r.Alive && !r.Detected
					}(j, name)
				}
				bwg.Wait()
				for j := range batch {
					if okIdx[j] {
						results[i] = found{asn: asn, name: batch[j], tried: start + j + 1}
						say(results[i])
						return
					}
				}
			}
			results[i] = found{asn: asn, name: "", tried: len(names)}
			say(results[i])
		}(i, asn, byASN[asn])
	}
	wg.Wait()

	var sb strings.Builder
	sb.WriteString("# Имя из белого списка на каждую сеть, где найден блок по объёму.\n")
	sb.WriteString("# Формат: <asn><TAB><имя>. Пересобирается пробой.\n")
	ok := 0
	for _, r := range results {
		if r.asn == "" {
			continue
		}
		if r.name != "" {
			sb.WriteString(r.asn)
			sb.WriteString("\t")
			sb.WriteString(r.name)
			sb.WriteString("\n")
			ok++
		}
	}
	fmt.Printf("\nимена найдены для %d сетей из %d\n", ok, len(keys))
	if out != "" {
		if err := os.WriteFile(out, []byte(sb.String()), 0o644); err != nil {
			fatal("не смог записать %s: %v", out, err)
		}
	}
	if ok == 0 {
		os.Exit(2)
	}
}

// scanNames ищет имя, с которым мишень перестаёт обрываться.
func scanNames(ctx context.Context, tg []tcp16.Target, names []string, par int, stopFirst bool) {
	// Сперва убеждаемся, что на этих мишенях блок вообще есть: иначе любое имя
	// «подойдёт», и мы запишем в находки первое попавшееся.
	base := runAll(ctx, tg, "", par)
	blocked := base[:0]
	for _, r := range base {
		if r.Detected {
			blocked = append(blocked, r)
		}
	}
	if len(blocked) == 0 {
		fmt.Println("на этих мишенях блока нет — искать нечего")
		os.Exit(2)
	}
	fmt.Printf("мишеней с блоком: %d, кандидатов: %d\n\n", len(blocked), len(names))

	found := 0
	for _, name := range names {
		ok := 0
		for _, b := range blocked {
			r := tcp16.Probe(ctx, b.Target, name)
			if r.Alive && !r.Detected {
				ok++
			}
		}
		if ok == len(blocked) {
			fmt.Printf("ПОДОШЛО %s (прошло %d/%d мишеней)\n", name, ok, len(blocked))
			found++
			if stopFirst {
				return
			}
		}
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
	if found == 0 {
		fmt.Println("ни одно имя из списка не прошло")
		os.Exit(2)
	}
}

func runAll(ctx context.Context, tg []tcp16.Target, sni string, par int) []tcp16.Result {
	if par < 1 {
		par = 1
	}
	out := make([]tcp16.Result, len(tg))
	sem := make(chan struct{}, par)
	var wg sync.WaitGroup
	for i, t := range tg {
		wg.Add(1)
		go func(i int, t tcp16.Target) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			c, cancel := context.WithTimeout(ctx, 40*time.Second)
			defer cancel()
			out[i] = tcp16.Probe(c, t, sni)
		}(i, t)
	}
	wg.Wait()
	return out
}

func loadTargets(path, asn string, confirmedOnly bool, limit int) ([]tcp16.Target, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("нет файла мишеней %s: %w", path, err)
	}
	defer f.Close()

	var out []tcp16.Target
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		p := strings.Split(line, "\t")
		if len(p) < 6 {
			continue
		}
		if asn != "" && p[1] != asn {
			continue
		}
		if confirmedOnly && p[2] != "*" {
			continue
		}
		port, err := strconv.Atoi(strings.TrimSpace(p[5]))
		if err != nil {
			continue
		}
		t := tcp16.Target{ID: p[0], ASN: p[1], Provider: p[3], IP: p[4], Port: port}
		// Седьмая колонка — имя для SNI, необязательная: файлы прежнего
		// формата читаются как раньше.
		if len(p) >= 7 {
			t.SNI = strings.TrimSpace(p[6])
		}
		out = append(out, t)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, sc.Err()
}

func loadNames(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("нет файла имён %s: %w", path, err)
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		s := sc.Text()
		if i := strings.IndexByte(s, '#'); i >= 0 {
			s = s[:i]
		}
		s = strings.TrimSpace(s)
		if s != "" {
			out = append(out, s)
		}
	}
	return out, sc.Err()
}
