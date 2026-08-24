// z2k-warpd — собственный WARP-движок z2k для Keenetic.
//
//	z2k-warpd register [--device PATH] [--proxy URL]
//	z2k-warpd run      [--device PATH] [--status PATH] [--log PATH] [--force-transport wg:PORT|h2] [-v]
//	z2k-warpd status   [--status PATH]
//	z2k-warpd version
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/engine"
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
	logMax        = 256 * 1024
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
	case "status":
		os.Exit(cmdStatus(os.Args[2:]))
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: z2k-warpd register|run|status|version [flags]")
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

func cmdRun(args []string) int {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	devPath := fs.String("device", defaultDevice, "device.json")
	stPath := fs.String("status", defaultStatus, "status.json")
	logPath := fs.String("log", defaultLog, "лог (tmpfs)")
	force := fs.String("force-transport", "", "wg:PORT | wg:HOST:PORT | h2 — только этот шаг")
	proxy := fs.String("proxy", os.Getenv("Z2K_WARP_VPS_PROXY"), "HTTPS-прокси (VPS-релей) для API, если напрямую заблокирован")
	verbose := fs.Bool("v", false, "подробный лог")
	fs.Parse(args)

	runtime.GOMAXPROCS(2)
	lw, err := logrot.New(*logPath, logMax)
	if err != nil {
		fmt.Fprintln(os.Stderr, "log:", err)
		return 1
	}
	defer lw.Close()
	logf := lw.Logf
	logf("z2k-warpd %s starting", version)

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
	if err := engine.Run(ctx, cfg); err != nil {
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
