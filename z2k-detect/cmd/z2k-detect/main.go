// z2k-detect — DPI-discovery daemon for z2k.
//
// Watches DNS queries from dnsmasq's log, probes domains the client just
// asked about, and on a Hot verdict appends the hostname to
// /opt/zapret2/lists/discovered-domains.txt. nfqws2 picks the file up
// via inotify and applies bypass to subsequent client requests, usually
// within seconds of the first failed connection.
//
// State is intentionally ephemeral: no SQLite, no TSV state machine,
// no Hot/Cache promotion ceremony. The discovered-domains.txt file is
// the canonical "we already added this" record; daemon reloads it on
// start. Operators manage cleanup the same way they always have —
// webpanel "Доп. домены" or direct edit + nfqws2 inotify.
//
// Subcommands:
//
//	probe <domain>   — one-shot diagnostic (no state touched)
//	run <logfile>    — daemon mode (tail + probe + append)
//
// # Почему ниже прибит GODEBUG
//
// Модуль долго стоял на директиве `go 1.22`, хотя собирается тулчейном
// go1.25.12. Из-за этого в бинарник вшивался совместимостный набор умолчаний
// go1.22 — и держался там незаметно. Бамп x/net до 0.57 (он закрывает
// GO-2026-4918, бесконечный цикл записи CONTINUATION в HTTP/2) требует
// директиву `go 1.25.0`, а её подъём сносит весь этот набор разом.
//
// Для обычной программы это ничего не значит. Для нас значит: мы ОПОЗНАЁМ DPI
// по тому, как провайдер отвечает на наш ClientHello, — то есть форма
// хендшейка это измерительный инструмент, а не деталь реализации. tlsmlkem=1
// добавил бы в ClientHello X25519MLKEM768 и заметно изменил его размер;
// tls3des/tlssha1 убрали бы из предложения легаси-наборы. Вердикты пробера
// поехали бы, и списали бы это на что угодно, кроме бампа библиотеки.
// Отдельно asynctimerchan: на MIPS у нас уже была история с async-preempt, и
// менять реализацию таймеров тем же коммитом — значит потерять возможность
// расследовать регресс.
//
// Поэтому прежний набор зафиксирован здесь ЯВНО. Бамп меняет только код
// библиотек, то есть ровно то, ради чего делается. Снимать эти строки можно
// только осознанно и по одной, с прогоном пробера на роутере до и после.
//
// Не прибиты сознательно: decoratemappings и gotestjsonbuildtext (только
// отладка и формат вывода тестов), winreadlinkvolume и winsymlink (Windows —
// на роутере не существуют).
//
//go:debug asynctimerchan=1
//go:debug containermaxprocs=0
//go:debug gotypesalias=0
//go:debug httpcookiemaxnum=0
//go:debug httpservecontentkeepheaders=1
//go:debug multipathtcp=0
//go:debug randseednop=0
//go:debug rsa1024min=0
//go:debug updatemaxprocs=0
//go:debug urlmaxqueryparams=0
//go:debug tls3des=1
//go:debug tlsmlkem=0
//go:debug tlssha1=1
//go:debug x509keypairleaf=0
//go:debug x509negativeserial=1
//go:debug x509rsacrt=0
//go:debug x509sha256skid=0
//go:debug x509usepolicies=0
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/classify"
	"github.com/necronicle/z2k/z2k-detect/internal/decision"
	"github.com/necronicle/z2k/z2k-detect/internal/dnssrc"
	"github.com/necronicle/z2k/z2k-detect/internal/engine"
	"github.com/necronicle/z2k/z2k-detect/internal/prober"
	"github.com/necronicle/z2k/z2k-detect/internal/sniwl"
)

func usage() {
	fmt.Fprintln(os.Stderr, `usage: z2k-detect <cmd> [args]
commands:
  probe <domain>            one-shot diagnostic probe, print verdict
  classify <host:port>      измерить, ЧЕМ режут, и вывести стратегию
  sniwl <domain|ip>         подобрать whitelisted-SNI для сети /16 этого адреса
  run [-dns-source SRC]     start daemon. SRC: agh|dnsmasq|pkt (default: auto)`)
}

func main() {
	flag.Usage = usage
	flag.Parse()
	args := flag.Args()

	if len(args) == 0 {
		usage()
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	switch args[0] {
	case "probe":
		probeCmd(ctx, args[1:])
	case "classify":
		classifyCmd(ctx, args[1:])
	case "sniwl":
		sniwlCmd(ctx, args[1:])
	case "run":
		runCmd(ctx, args[1:])
	default:
		fatal("unknown command: %s", args[0])
	}
}

// classifyCmd измеряет функцию решения DPI и печатает вердикт со стратегией.
//
// Отличие от probe: probe отвечает «работает или нет», classify — «чем именно
// режут и что с этим делать». Состояния не трогает, в списки не пишет.
func classifyCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("classify", flag.ExitOnError)
	sni := fs.String("sni", "", "собрать триггер как ClientHello с этим именем")
	raw := fs.String("raw", "", "триггер шестнадцатеричной строкой (для не-TLS протоколов)")
	repeats := fs.Int("repeats", 3, "повторов на зонд; вердикт только при единогласии")
	timeout := fs.Duration("timeout", 6*time.Second, "сколько ждать ответа")
	transfer := fs.Bool("transfer", false, "зонд объёма: доезжает ли ответ целиком (ловит троттлинг)")
	echo := fs.Bool("raw-echo", false, "положительный контроль: сырое рукопожатие + триггер без приёмов")
	only := fs.String("only", "", "прогнать только эту гипотезу (для отладки зондов)")
	ctlSNI := fs.String("control-sni", "", "имя для контрольного зонда; сервер обязан его обслуживать")
	asJSON := fs.Bool("json", false, "выдать Result как JSON")
	_ = fs.Parse(rest)
	if fs.NArg() < 1 {
		fatal("classify: не указан адрес host:port")
	}
	addr := fs.Arg(0)

	var (
		tr  classify.Trigger
		err error
	)
	switch {
	case *raw != "" && *sni != "":
		fatal("classify: -sni и -raw взаимоисключающие")
	case *raw != "":
		tr, err = classify.RawTrigger(*raw)
	default:
		name := *sni
		if name == "" {
			// Имя не задано — берём его из адреса. Для TLS это ровно то, по
			// чему DPI и принимает решение, так что умолчание осмысленное.
			if h, _, e := net.SplitHostPort(addr); e == nil {
				name = h
			}
		}
		tr, err = classify.TLSTrigger(name)
	}
	if err != nil {
		fatal("%v", err)
	}

	// Контроль собираем всегда, когда он вообще собирается: без него вердикт
	// «непрозрачно» склеивает два разных мира — пересборку и блок по адресу.
	opts := classify.Options{Repeats: *repeats, Timeout: *timeout, Only: *only}
	// Контроль тем же именем, что и триггер, — не контроль вовсе: если имя под
	// блокировкой, молчать будут оба, и вердикт «режут адрес» получится из
	// собственной ошибки ввода.
	if *ctlSNI != "" && *ctlSNI == *sni {
		fatal("classify: -control-sni совпадает с -sni; контролем должно быть ДРУГОЕ имя, заведомо не блокируемое")
	}
	if *ctlSNI != "" {
		// Имя названо руками — значит за базу ручается оператор, и молчание
		// контроля можно засчитать как блок по адресу.
		if ctl, cerr := classify.TLSTrigger(*ctlSNI); cerr == nil {
			ctl.Name = "control:" + *ctlSNI
			opts.Control, opts.ControlVouched = ctl, true
		}
	} else if ctl, cerr := classify.ControlTrigger("z2k"); cerr == nil {
		opts.Control = ctl
	}
	if *transfer {
		name := *sni
		if name == "" {
			if h, _, e := net.SplitHostPort(addr); e == nil {
				name = h
			}
		}
		tr, terr := classify.TransferProbe(ctx, addr, name, *timeout)
		if terr != nil {
			fatal("transfer: %v", terr)
		}
		if *asJSON {
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			_ = enc.Encode(tr)
			return
		}
		fmt.Printf("Цель:     %s (%s)\n", tr.Host, tr.Addr)
		fmt.Printf("Вердикт:  %s — %s\n", tr.Verdict, tr.Reason)
		fmt.Printf("Ответ:    код %d, объявлено %d, получено тела %d, всего %d байт за %d мс\n",
			tr.Status, tr.ContentLength, tr.BodyBytes, tr.TotalBytes, tr.DurationMS)
		fmt.Printf("Закрытие: %v\n", tr.ClosedByPeer)
		return
	}
	if *echo {
		ok, err := classify.RawEcho(ctx, addr, tr, *timeout)
		if err != nil {
			fatal("raw-echo: %v", err)
		}
		if ok {
			fmt.Println("raw-echo: ОТВЕТ ЕСТЬ — путь данных сырого слоя рабочий")
		} else {
			fmt.Println("raw-echo: тишина — либо цель под блокировкой, либо сервер не берёт наши сегменты")
		}
		return
	}
	res := classify.Run(ctx, addr, tr, opts)

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(res)
		return
	}
	fmt.Printf("Цель:     %s\n", res.Target)
	fmt.Printf("Триггер:  %s (%d байт)\n", tr.Name, res.TriggerLen)
	fmt.Printf("Вердикт:  %s — %s\n", res.Verdict, res.Reason)
	fmt.Printf("Зондов:   %d за %s (по %d повтора)\n", res.Probes, res.Duration, res.Repeats)
	if res.Boundary > 0 {
		fmt.Printf("Граница:  сигнатура кончается на байте %d\n", res.Boundary)
	}
	if res.Reassembles != nil {
		if *res.Reassembles {
			fmt.Printf("Пересборка: ЕСТЬ — при паузе блок возвращается\n")
		} else {
			fmt.Printf("Пересборка: нет\n")
		}
	}
	if res.Strategy != "" {
		how := map[string]string{
			"свойство": "ответила фаза свойств — 6 вопросов о коробке",
			"собрано":  "СОБРАНА из вектора свойств",
			"перебор":  "вектор не помог, найдена запасным перебором",
		}[res.Path]
		if how == "" {
			how = "путь не отмечен"
		}
		fmt.Printf("Стратегия: %s\n           (%s)\n", res.Strategy, how)
	}
	if res.Verdict == classify.VerdictOpaque && !res.RawUsable {
		fmt.Printf("ВНИМАНИЕ: сырые зонды не отработали — отрицательный вывод про отравление НЕ значим\n")
	}
	pr := res.Props
	if pr.Reassembles != nil || pr.ParsesL7 != nil || pr.ValidatesChecksum != nil ||
		pr.ToleratesReorder != nil || pr.ToleratesLeftOverlap != nil || pr.HopTTL > 0 {
		fmt.Println("Свойства коробки:")
		yn := func(b *bool) string {
			if b == nil {
				return "не измерено"
			}
			if *b {
				return "да"
			}
			return "нет"
		}
		fmt.Printf("  пересобирает поток:        %s\n", yn(pr.Reassembles))
		fmt.Printf("  разбирает протокол:        %s\n", yn(pr.ParsesL7))
		fmt.Printf("  проверяет контр. сумму:    %s\n", yn(pr.ValidatesChecksum))
		fmt.Printf("  держит переупорядочивание: %s\n", yn(pr.ToleratesReorder))
		fmt.Printf("  держит перекрытие слева:   %s\n", yn(pr.ToleratesLeftOverlap))
		if pr.HopTTL > 0 {
			fmt.Printf("  расстояние до неё:         %d хопов\n", pr.HopTTL)
		}
	}
	fmt.Println("Трасса:")
	for _, o := range res.Trace {
		cuts := "-"
		if len(o.Cuts) > 0 {
			cuts = fmt.Sprint(o.Cuts)
		}
		fmt.Printf("  %-11s cuts=%-8s пауза=%dмс  прошло=%d не прошло=%d %s\n",
			o.Probe, cuts, o.DelayM, o.Pass, o.Fail, o.Err)
	}
}

// probeCmd runs a one-shot probe + prints a z2k-friendly verdict line.
// Stateless: never opens the daemon's runtime state, never writes to
// discovered-domains.txt. Used by menu [Y] and operator triage.
func probeCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "emit raw probe Result as JSON")
	_ = fs.Parse(rest)
	if fs.NArg() < 1 {
		fatal("probe: missing domain")
	}
	domain := fs.Arg(0)
	if err := prober.Validate(domain); err != nil {
		fatal("%v", err)
	}
	res := prober.Probe(ctx, domain, 0)

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(res)
		return
	}

	fmt.Printf("Domain:  %s\n", res.Domain)
	fmt.Printf("Probe:   DNS=%s TCP=%s TLS=%s HTTP=%s  (%dms)\n",
		okStr(&res.DNSOK), okStr(&res.TCPOK), okStr(&res.TLSOK),
		okStrPtr(res.HTTPOK), res.LatencyMS)
	if len(res.ResolvedIPs) > 0 {
		fmt.Printf("IPs:     %s\n", joinIPs(res.ResolvedIPs))
	}
	if res.FailureCode != "" {
		fmt.Printf("Code:    %s\n", res.FailureCode)
	}
	if res.FailureReason != "" {
		fmt.Printf("Reason:  %s\n", res.FailureReason)
	}
	// Первый вопрос по любому домену — «обход тут вообще поможет?».
	// Печатаем сразу под причиной, чтобы человек не гадал по кодам.
	switch res.PathVerdict {
	case prober.PathSNI:
		fmt.Printf("Блок:    ПО ИМЕНИ — %s\n", res.PathReason)
		fmt.Println("  → это наш случай, обход применим.")
	case prober.PathIP:
		fmt.Printf("Блок:    ПО АДРЕСУ — %s\n", res.PathReason)
		fmt.Println("  → пакетными техниками не обходится: движок не может обойти блок по IP.")
		fmt.Println("    Помогает только другой адрес (свежий резолв) или туннель — WARP/релей.")
	case prober.PathServer:
		fmt.Printf("Блок:    НЕТ — %s\n", res.PathReason)
	}

	verdict := decision.Classify(res)
	inList := findDomainInZ2kLists(domain)

	switch verdict {
	case decision.Hot:
		// Raw probe прошёл через SO_MARK-обход → видим прямое поведение
		// DPI без нашего bypass'а. Сайт реально заблокирован.
		if inList != "" {
			fmt.Printf("Verdict: HOT — DPI блокирует, но домен уже в списке: %s.\n", inList)
			fmt.Println("  → ничего делать не надо, autocircular подбирает страту автоматически.")
		} else {
			fmt.Println("Verdict: HOT — DPI блокирует, домен НЕ в списках.")
			fmt.Printf("  → добавить в bypass: `echo %s >> /opt/zapret2/lists/extra-domains.txt`\n", domain)
			fmt.Println("    или через webpanel «Доп. домены» — nfqws2 подхватит за секунды.")
		}
	case decision.Watch:
		// Блок по адресу. Строка «Блок: ПО АДРЕСУ» выше уже объяснила почему;
		// здесь только вывод, что делать. В bypass такой домен добавлять
		// нельзя: ротатор впустую переберёт весь арсенал пула.
		fmt.Println("Verdict: WATCH — блокируют по адресу, обход бессилен.")
		if inList != "" {
			fmt.Printf("  → домен уже в списке (%s) — оттуда его лучше УБРАТЬ: autocircular будет\n", inList)
			fmt.Println("    впустую крутить стратегии, а заодно двигать их для остальных доменов пула.")
		} else {
			fmt.Println("  → в bypass добавлять НЕ надо, ротация тут ничего не подберёт.")
		}
		fmt.Println("    Помогает другой адрес (свежий резолв) либо туннель — WARP/релей.")
	case decision.Ignore:
		switch {
		case !res.DNSOK && (res.FailureCode == prober.CodeDNSNXDomain || res.FailureCode == prober.CodeNoIPs):
			fmt.Println("Verdict: IGNORE — домен не существует (NXDOMAIN).")
			fmt.Println("  → проверь опечатку в имени; смотри Reason — какой конкретно резолвер так ответил.")
		case !res.DNSOK && res.FailureCode == prober.CodeDNSTimeout:
			fmt.Println("Verdict: IGNORE — DNS-резолверы не ответили (см. Reason какой именно).")
			fmt.Println("  → если все таймаут — сетевая проблема на роутере (UDP/53 outgoing); если только локальный — фиксить локальный резолвер.")
		case !res.DNSOK:
			fmt.Println("Verdict: IGNORE — DNS-стадия не прошла, проблема не у DPI.")
			fmt.Println("  → подробности в Reason.")
		case prober.IsServerReachable(res.FailureCode):
			fmt.Println("Verdict: IGNORE — сервер отвечает (TLS alert / mTLS) — server-side политика, не DPI.")
			fmt.Println("  → bypass не поможет; для mTLS нужен client cert на устройстве клиента.")
		default:
			// Соединение работает.
			if inList != "" {
				fmt.Printf("Verdict: IGNORE — соединение работает, домен уже в списке: %s.\n", inList)
				fmt.Println("  → если у юзера сайт реально не открывается — это не DPI-проблема, копать где-то ещё (DNS/маршрутизация/устройство).")
			} else {
				fmt.Println("Verdict: IGNORE — соединение работает напрямую, обход не нужен.")
				fmt.Println("  → если у юзера сайт не открывается — это локальная проблема устройства/провайдера, не DPI.")
			}
		}
	}
}

// runCmd starts the engine daemon. Returns cleanly on SIGTERM/SIGINT
// (context.Canceled), non-zero on any other error.
func runCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	dnsSrc := fs.String("dns-source", "", "DNS observation source: agh|dnsmasq|pkt. Empty = auto-detect (AGH → dnsmasq → AF_PACKET sniff)")
	publishPath := fs.String("publish", "/opt/zapret2/lists/discovered-domains.txt", "where to append HOT-verdict hostnames")
	sniwlOn := fs.Bool("sniwl", true, "подбор whitelisted-SNI для класса «поток встаёт на 16–20 КБ»")
	_ = fs.Parse(rest)

	cfg := engine.Defaults()
	cfg.PublishPath = *publishPath
	// Новая подсистема включена по умолчанию, как и остальные наши флаги.
	// Выключается флагом или конфигом. Z2K_SNI_WL_FAKE — тот же тумблер, что
	// гейтит генерацию профиля: выключив профиль, оператор сказал, что этот
	// приём ему не нужен, и гонять ради него мусор в аплинк было бы тратой
	// его канала без единого следствия.
	cfg.SNIWL.Enabled = *sniwlOn
	if os.Getenv("Z2K_SNIWL") == "0" || os.Getenv("Z2K_SNI_WL_FAKE") == "0" {
		cfg.SNIWL.Enabled = false
	}
	if *dnsSrc != "" {
		src, err := dnssrc.Detect(*dnsSrc)
		if err != nil {
			fatal("%v", err)
		}
		cfg.DNSSource = src
	}

	err := engine.Run(ctx, cfg)
	// SIGTERM from init.d arrives as context cancellation — engine.Run
	// returns ctx.Err() (== context.Canceled). That's not a fatal; let
	// the process exit zero so the supervisor sees a clean stop.
	if err != nil && err != context.Canceled {
		fatal("engine: %v", err)
	}
	fmt.Fprintln(os.Stderr, "engine: stopped")
}

// sniwlCmd — разовый подбор whitelisted-SNI для сети /16 указанного адреса.
//
// Отвечает на два вопроса подряд: «режет ли эта сеть поток по объёму» и «какое
// имя из белого списка коробки её пробивает». Без -write состояния не трогает
// вовсе — это триаж, а не раскатка.
func sniwlCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("sniwl", flag.ExitOnError)
	candPath := fs.String("candidates", sniwl.DefaultCandidatesPath, "файл кандидатов; порядок в нём = приоритет")
	netPath := fs.String("networks", sniwl.DefaultNetworksPath, "файл поражённых сетей (--ipset профиля)")
	namePath := fs.String("name", sniwl.DefaultNamePath, "файл имени-победителя")
	maxCand := fs.Int("max", sniwl.DefaultMaxCandidates, "потолок кандидатов за прогон")
	conc := fs.Int("concurrency", sniwl.DefaultSweepConcurrency, "одновременных проб")
	pause := fs.Duration("pause", sniwl.DefaultBatchPause,
		"пауза между батчами (0 — умолчание, отрицательное — без паузы)")
	baseline := fs.String("baseline", sniwl.DefaultBaselineSNI, "нейтральное имя контрольного плеча")
	write := fs.Bool("write", false, "записать находку в файлы состояния (по умолчанию только печать)")
	asJSON := fs.Bool("json", false, "выдать результат как JSON")
	_ = fs.Parse(rest)
	if fs.NArg() < 1 {
		fatal("sniwl: не указан домен или адрес")
	}
	target := fs.Arg(0)

	ips := []string{target}
	if net.ParseIP(target) == nil {
		res := prober.Probe(ctx, target, 0)
		if len(res.ResolvedIPs) == 0 {
			fatal("sniwl: %s не резолвится (%s)", target, res.FailureCode)
		}
		ips = res.ResolvedIPs
	}
	ip, key, ok := sniwl.FirstRoutable(ips)
	if !ok {
		fatal("sniwl: среди адресов %v нет ни одного публичного IPv4", ips)
	}

	cands, err := sniwl.LoadCandidates(*candPath)
	if err != nil {
		fatal("%v", err)
	}
	store := sniwl.NewStore(*netPath, *namePath)
	incumbent, _ := store.LoadName()
	cands = sniwl.OrderWithIncumbent(cands, incumbent)

	cfg := sniwl.SweepConfig{
		BaselineSNI:   *baseline,
		MaxCandidates: *maxCand,
		Concurrency:   *conc,
		BatchPause:    *pause,
	}
	out := sniwl.RunSweep(ctx, net.JoinHostPort(ip, "443"), cands, cfg)
	out.Network = sniwl.CIDR(key)

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(out)
	} else {
		fmt.Printf("Цель:      %s → %s (сеть %s)\n", target, out.Addr, out.Network)
		fmt.Printf("Контроль:  %s (%s) — %s, аплинк %d Б, кусок %d\n",
			out.Baseline.Status, *baseline, out.Baseline.Detail, out.Baseline.UplinkBytes, out.Baseline.Chunk)
		fmt.Printf("Без SNI:   %s — %s\n", out.NoSNI.Status, out.NoSNI.Detail)
		if out.Recheck.Status != "" {
			fmt.Printf("Переконтроль: %s — %s\n", out.Recheck.Status, out.Recheck.Detail)
		}
		fmt.Printf("Сеть:      состояние=%s режет=%v имя-триггер=%v\n", out.State, out.Affected, out.NoSNIWorks)
		switch {
		case out.Winner != "":
			fmt.Printf("Имя:       %s (строка %d), проб сделано %d, за %s\n",
				out.Winner, out.WinnerLine, out.Tried, out.Took.Round(time.Millisecond))
		case out.State == sniwl.StateInconclusive:
			// Не «имени нет», а «мы не узнали»: адрес перестал отвечать так
			// же, как в начале, и последние пробы были не про имена.
			fmt.Printf("Имя:       НЕУБЕДИТЕЛЬНО, проб сделано %d за %s — мерить заново позже\n",
				out.Tried, out.Took.Round(time.Millisecond))
		default:
			fmt.Printf("Имя:       не найдено, проб сделано %d за %s\n", out.Tried, out.Took.Round(time.Millisecond))
		}
		fmt.Printf("Итог:      %s\n", out.Reason)
	}

	if !*write {
		return
	}
	if out.State != sniwl.StateFound {
		fmt.Fprintf(os.Stderr, "sniwl: писать нечего — состояние прогона %s\n", out.State)
		os.Exit(1)
	}
	detail := fmt.Sprintf("%s | ручной прогон | имя %s (строка %d) | контроль встал на %d Б",
		out.Network, out.Winner, out.WinnerLine, out.Baseline.UplinkBytes)
	// Имя пишем ПЕРВЫМ: профиль гейтится непустым файлом сетей, и обратный
	// порядок открыл бы окно «профиль собирается, подставлять нечего».
	if err := store.SetName(out.Winner, detail); err != nil {
		fatal("sniwl: %v", err)
	}
	added, err := store.AddNetwork(key, detail)
	if err != nil {
		fatal("sniwl: %v", err)
	}
	if added {
		fmt.Printf("Записано:  %s → %s, имя → %s\n", out.Network, *netPath, *namePath)
	} else {
		fmt.Printf("Записано:  имя → %s (сеть %s уже была в %s)\n", *namePath, out.Network, *netPath)
	}
}

func okStr(b *bool) string {
	if b == nil {
		return "skip"
	}
	if *b {
		return "ok"
	}
	return "fail"
}

func okStrPtr(b *bool) string {
	if b == nil {
		return "skip"
	}
	if *b {
		return "ok"
	}
	return "fail"
}

func joinIPs(ips []string) string {
	out := ""
	for i, ip := range ips {
		if i > 0 {
			out += ", "
		}
		out += ip
	}
	return out
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	os.Exit(1)
}
