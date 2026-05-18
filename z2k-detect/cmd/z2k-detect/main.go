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
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/necronicle/z2k/z2k-detect/internal/decision"
	"github.com/necronicle/z2k/z2k-detect/internal/dnssrc"
	"github.com/necronicle/z2k/z2k-detect/internal/engine"
	"github.com/necronicle/z2k/z2k-detect/internal/prober"
)

func usage() {
	fmt.Fprintln(os.Stderr, `usage: z2k-detect <cmd> [args]
commands:
  probe <domain>            one-shot diagnostic probe, print verdict
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
	case "run":
		runCmd(ctx, args[1:])
	default:
		fatal("unknown command: %s", args[0])
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
	_ = fs.Parse(rest)

	cfg := engine.Defaults()
	cfg.PublishPath = *publishPath
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
