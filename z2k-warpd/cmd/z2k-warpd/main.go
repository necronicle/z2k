// z2k-warpd — собственный WARP-движок z2k для Keenetic.
//
//	z2k-warpd register [--device PATH] [--proxy URL]
//	z2k-warpd run      [--device PATH] [--status PATH] [--log PATH] [--force-transport wg:PORT|h2] [-v]
//	z2k-warpd license  [--device PATH] [--proxy URL]   < ключ WARP+ (пусто — только перечитать аккаунт)
//	z2k-warpd status   [--status PATH]
//	z2k-warpd version
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/domainroute"
	"github.com/necronicle/z2k/z2k-warpd/internal/edgepick"
	"github.com/necronicle/z2k/z2k-warpd/internal/engine"
	"github.com/necronicle/z2k/z2k-warpd/internal/ladder"
	"github.com/necronicle/z2k/z2k-warpd/internal/logrot"
	"github.com/necronicle/z2k/z2k-warpd/internal/status"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport/h2"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport/wg"
)

var version = "dev"

const (
	defaultDevice = "/opt/etc/z2k-warp/device.json"
	defaultStatus = "/tmp/z2k-warp/status.json"
	defaultLog    = "/tmp/z2k-warp/warpd.log"
	// Запасные эндпоинты — ДАННЫЕ. Файл доставляется обновлением и правится без
	// пересборки бинарников под пять арок; нет файла — работает встроенный
	// список.
	//
	// РЯДОМ С каталогом lists/warp, а НЕ внутри: туда складывают
	// пользовательские списки адресов, и всё, что там лежит, попадает в ipset
	// z2k_warp. Наши эндпоинты оказались бы завёрнуты в тот самый туннель,
	// через который к ним и идёт подключение.
	defaultEndpoints = "/opt/zapret2/lists/warp-endpoints.txt"
	defaultScanPools = "/opt/zapret2/lists/warp-scan-pools.txt"
	logMax           = 256 * 1024
	memLimit         = 48 << 20
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "version":
		fmt.Println("z2k-warpd", version)
	case "register":
		os.Exit(cmdRegister(os.Args[2:]))
	case "run":
		os.Exit(cmdRun(os.Args[2:]))
	case "license":
		os.Exit(cmdLicense(os.Args[2:]))
	case "status":
		os.Exit(cmdStatus(os.Args[2:]))
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: z2k-warpd register|run|license|status|version [flags]")
	os.Exit(2)
}

// cmdRegister: есть device.json — проверить, что устройство живо (GET);
// нет — завести (POST + PATCH). stderr — код ошибки для панели.
func cmdRegister(args []string) int {
	fs := flag.NewFlagSet("register", flag.ExitOnError)
	devPath := fs.String("device", defaultDevice, "device.json")
	proxy := fs.String("proxy", "", "HTTPS proxy для регистрации (VPS-релей)")
	fs.Parse(args)

	client := &account.Client{HTTP: &http.Client{Timeout: 25 * time.Second}}
	if *proxy != "" {
		u, err := url.Parse(*proxy)
		if err != nil {
			fmt.Fprintln(os.Stderr, status.ErrRegisterBlocked, "bad --proxy")
			return 1
		}
		client.HTTP.Transport = &http.Transport{Proxy: http.ProxyURL(u)}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	d, created, err := client.Ensure(ctx, *devPath)
	if err != nil {
		if errors.Is(err, account.ErrRevoked) {
			fmt.Fprintln(os.Stderr, status.ErrDeviceRevoked, err)
		} else {
			fmt.Fprintln(os.Stderr, status.ErrRegisterBlocked, err)
		}
		return 1
	}
	if created {
		fmt.Println("registered", d.ID)
	} else {
		fmt.Println("device ok", d.ID)
	}
	return 0
}

// cmdLicense — ключ WARP+.
//
// КЛЮЧ ЧИТАЕТСЯ ИЗ STDIN, А НЕ АРГУМЕНТОМ. Аргументы процесса видны любому в
// списке процессов роутера и попадают в лог задачи панели дословно; ключ —
// платная подписка человека.
//
// Коды: 0 — готово; 1 — API недоступен (вызывающий пробует через релей);
// 2 — ключ не похож на ключ; 3 — Cloudflare отказал (повтор через релей даст
// тот же отказ, пробовать незачем); 4 — нет записи устройства.
// Пустой ввод — только перечитать тип аккаунта.
func cmdLicense(args []string) int {
	fs := flag.NewFlagSet("license", flag.ExitOnError)
	devPath := fs.String("device", defaultDevice, "device.json")
	proxy := fs.String("proxy", "", "HTTPS proxy (VPS-релей)")
	fs.Parse(args)

	d, err := account.Load(*devPath)
	if err != nil || d.ID == "" {
		fmt.Fprintln(os.Stderr, "no_device: устройство не зарегистрировано — сначала установите WARP")
		return 4
	}
	raw, _ := io.ReadAll(io.LimitReader(os.Stdin, 512))
	key := strings.TrimSpace(string(raw))
	if key != "" && !licenseKeyOK(key) {
		fmt.Fprintln(os.Stderr, "bad_key: ключ состоит из латинских букв, цифр и дефисов")
		return 2
	}

	client := &account.Client{HTTP: &http.Client{Timeout: 25 * time.Second}}
	if *proxy != "" {
		u, perr := url.Parse(*proxy)
		if perr != nil {
			fmt.Fprintln(os.Stderr, status.ErrRegisterBlocked, "bad --proxy")
			return 1
		}
		client.HTTP.Transport = &http.Transport{Proxy: http.ProxyURL(u)}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	var a *account.AccountInfo
	if key != "" {
		a, err = client.ApplyLicense(ctx, d, key)
	} else {
		a, err = client.Account(ctx, d)
	}
	if err != nil {
		var ae *account.APIError
		switch {
		case errors.As(err, &ae):
			fmt.Fprintln(os.Stderr, "license_rejected:", ae.Error())
			return 3
		case errors.Is(err, account.ErrRevoked):
			fmt.Fprintln(os.Stderr, status.ErrDeviceRevoked, err)
			return 3
		}
		fmt.Fprintln(os.Stderr, status.ErrRegisterBlocked, err)
		return 1
	}
	if key != "" {
		if err := account.SaveLicense(*devPath, key); err != nil {
			fmt.Fprintln(os.Stderr, "ключ применён, но не сохранился:", err)
		}
	}
	a.Checked = time.Now().Unix()
	if err := account.SaveAccountInfo(*devPath, a); err != nil {
		fmt.Fprintln(os.Stderr, "account.json:", err)
	}
	fmt.Printf("account_type=%s plus=%t premium_data=%.0f quota=%.0f\n", a.AccountType, a.Plus(), a.PremiumData, a.Quota)
	return 0
}

// licenseKeyOK — грубая проверка формы. Точный формат ключа Cloudflare не
// публикует; всё, что сюда проходит, безопасно отправить в JSON и записать в
// файл, а правильность решает сам API.
func licenseKeyOK(k string) bool {
	if len(k) < 8 || len(k) > 64 {
		return false
	}
	for _, r := range k {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
			return false
		}
	}
	return true
}

// repairBadEndpoint — см. account.RepairBadEndpoint. Отдельная функция, чтобы
// сеть и таймаут не размазывались по телу cmdRun.
func repairBadEndpoint(devPath, proxy string, logf func(string, ...any)) {
	cl := &account.Client{HTTP: &http.Client{Timeout: 25 * time.Second}}
	if proxy != "" {
		if u, err := url.Parse(proxy); err == nil {
			cl.HTTP.Transport = &http.Transport{Proxy: http.ProxyURL(u)}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	fresh, done, err := cl.RepairBadEndpoint(ctx, devPath)
	switch {
	case err != nil:
		logf("endpoint: перерегистрация не удалась (%v) — поднимаюсь со старой записью", err)
	case done:
		logf("endpoint: выданный адрес из блокируемого диапазона — устройство перерегистрировано, новый %s", fresh.Endpoint.V4)
	}
}

// readEndpoints — по адресу на строку, «#» комментарий. Мусор пропускаем
// молча: файл правят руками, и одна кривая строка не должна лишать роутера
// всех запасных адресов.
func readEndpoints(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if net.ParseIP(line) == nil {
			continue
		}
		out = append(out, line)
	}
	return out
}

func cmdRun(args []string) int {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	devPath := fs.String("device", defaultDevice, "device.json")
	stPath := fs.String("status", defaultStatus, "status.json")
	logPath := fs.String("log", defaultLog, "лог (tmpfs)")
	force := fs.String("force-transport", "", "wg:PORT | wg:HOST:PORT | h2 — только этот шаг")
	// Режим — через переменную окружения по умолчанию, а не только флагом.
	// Init-скрипт экспортирует её из конфига; движок старой сборки её просто
	// не видит и работает автоматом. Флаг, переданный старому движку, уронил
	// бы его на разборе аргументов — и человек, выбравший транспорт до
	// обновления бинарника, остался бы без WARP вовсе.
	modeArg := fs.String("transport", os.Getenv("Z2K_WARP_TRANSPORT"), "auto | wg | h2 — какими транспортами ходить")
	proxy := fs.String("proxy", os.Getenv("Z2K_WARP_VPS_PROXY"), "HTTPS-прокси (VPS-релей) для API, если напрямую заблокирован")
	epPath := fs.String("endpoints", defaultEndpoints, "список запасных эндпоинтов")
	poolPath := fs.String("scan-pools", defaultScanPools, "небольшой список сетей для выбора узла WARP")
	verbose := fs.Bool("v", false, "подробный лог")
	fs.Parse(args)

	runtime.GOMAXPROCS(2)
	// Мягкий потолок кучи. Живой набор под нагрузкой — около 10 МБ, и сборщик
	// по умолчанию держал бы вдвое больше; лимит заставляет его прибираться
	// раньше, чем роутер с 128–256 МБ заметит. Это страховка, а не решение:
	// буферы под пакеты урезаны в third_party/wireguard, без этого лимит
	// пик не срезал (VmHWM 84 МБ при лимите 40 МБ, замер 2026-09-02).
	debug.SetMemoryLimit(memLimit)
	lw, err := logrot.New(*logPath, logMax)
	if err != nil {
		fmt.Fprintln(os.Stderr, "log:", err)
		return 1
	}
	defer lw.Close()
	logf := lw.Logf
	logf("z2k-warpd %s starting", version)

	// Запасные адреса из файла. Молчим, если его нет: это штатное состояние —
	// работает встроенный список.
	if hosts := readEndpoints(*epPath); len(hosts) > 0 {
		ladder.SetFallbackHosts(hosts)
		logf("запасных эндпоинтов из %s: %d", *epPath, len(hosts))
	}

	// ПОЧИНКА НЕГОДНОГО АДРЕСА — ЗДЕСЬ, А НЕ ТОЛЬКО В register.
	//
	// Запись, которой Cloudflare выдал первичный адрес из блокируемого
	// целиком диапазона, не заработает никогда: вся лестница оказывается
	// внутри него, и в логе видно четыре попытки на один и тот же адрес.
	// Проверка жила в Ensure, а её зовёт только «Установить WARP» — до тех,
	// у кого WARP уже стоял, она не доезжала вовсе.
	//
	// FAIL-OPEN: не вышло перерегистрировать — идём поднимать туннель со
	// старой записью. Она мертва, но отказ стартовать оставил бы человека без
	// диагноза, а с ней в статусе видно, ЧТО именно не работает.
	repairBadEndpoint(*devPath, *proxy, logf)

	cfg := engine.Config{
		DevicePath: *devPath,
		StatusPath: *stPath,
		Logf:       logf,
		Proxy:      *proxy,
		NewTransport: func(step account.Step, dev tun.Device, d *account.Device) (transport.Transport, error) {
			switch step.Transport {
			case "wg":
				return wg.New(dev, d, step.Host, step.Port, logf)
			case "h2":
				return h2.New(dev, d, logf)
			}
			return nil, fmt.Errorf("unknown transport %q", step.Transport)
		},
	}
	if device, err := account.Load(*devPath); err == nil {
		pools := edgepick.ReadPools(*poolPath)
		cfg.EdgeCandidates = edgepick.Candidates(device.Endpoint, ladder.FallbackHosts(), pools, 12, uint64(time.Now().Unix()/86400))
		logf("edge: %d candidates from %d pools", len(cfg.EdgeCandidates), len(pools))
	}
	mode, modeOK := ladder.ParseMode(*modeArg)
	if !modeOK {
		logf("неизвестный режим транспорта %q — работаю автоматически", *modeArg)
	}
	cfg.Mode = mode
	if mode != ladder.ModeAuto {
		logf("транспорт выбран вручную: %s", mode)
	}
	if *force != "" {
		s, err := parseForce(*force)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 2
		}
		cfg.ForceStep = &s
		logf("forced transport %s", s.Transport+":"+s.Host+":"+strconv.Itoa(s.Port))
	}
	_ = verbose

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	rules, _ := domainroute.ParseRules([]byte("v1\n"))
	observer := domainroute.NewObserver(rules)
	options := domainroute.Options{
		DomainPath: "/tmp/z2k-warp/domains.v1", SnapshotPath: "/tmp/z2k-warp/domain-pairs.v1",
		StatusPath: "/tmp/z2k-warp/domain-status.json", PairSet: domainroute.PairSet{},
	}
	if err := runEngineAndObserver(ctx, func(c context.Context) error { return engine.Run(c, cfg) }, func(c context.Context) error { return observer.Run(c, options) }); err != nil {
		// Другой экземпляр уже держит туннель — это нормальный исход гонки
		// (selfheal и enable могут стартовать одновременно), а не сбой.
		if errors.Is(err, engine.ErrAlreadyRunning) {
			logf("движок уже запущен другим процессом — выхожу")
			return 0
		}
		logf("fatal: %v", err)
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	logf("stopped")
	return 0
}

func parseForce(s string) (account.Step, error) {
	if s == "h2" {
		return account.Step{Transport: "h2", Port: 443}, nil
	}
	if strings.HasPrefix(s, "wg:") {
		rest := strings.TrimPrefix(s, "wg:")
		host := ""
		if i := strings.LastIndex(rest, ":"); i > 0 {
			host, rest = rest[:i], rest[i+1:]
		}
		p, err := strconv.Atoi(rest)
		if err == nil && p > 0 && p < 65536 {
			return account.Step{Transport: "wg", Host: host, Port: p}, nil
		}
	}
	return account.Step{}, fmt.Errorf("bad --force-transport %q (wg:PORT | wg:HOST:PORT | h2)", s)
}

// cmdStatus печатает status.json; 0 — ready, 2 — не ready, 1 — файла нет.
func cmdStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	stPath := fs.String("status", defaultStatus, "status.json")
	fs.Parse(args)
	b, err := os.ReadFile(*stPath)
	if err != nil {
		return 1
	}
	os.Stdout.Write(b)
	fmt.Println()
	s, err := status.Read(*stPath)
	if err != nil || !s.Ready {
		return 2
	}
	return 0
}
