package gvsub

import (
	"bufio"
	"context"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Config — параметры запуска службы.
type Config struct {
	Queue      uint16 // очередь с ответами DNS
	StatusPath string
	Conntrack  string // /proc/net/nf_conntrack
	NoIPv6     bool   // IPv6 выключен в z2k
	// Owner — init-скрипт, который запускает службу, и ConfigPath — конфиг z2k.
	// Служба уходит сама и снимает свой каркас, если init её больше не знает
	// (ночное обновление 10.11.2026 вернуло init без неё, а служба осталась
	// держать ответы DNS) или подмена выключена в конфиге.
	Owner      string
	ConfigPath string
	// IPFile — адреса googlevideo из ответов DNS, для профиля движка с --ipset.
	IPFile string
}

// wanted — нужна ли ещё служба.
func wanted(cfg Config) bool {
	if cfg.Owner != "" {
		b, err := os.ReadFile(cfg.Owner)
		if err != nil || !strings.Contains(string(b), "z2k_gvsub_start") {
			return false
		}
	}
	if cfg.ConfigPath != "" {
		if f, err := os.Open(cfg.ConfigPath); err == nil {
			v := ""
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				if rest, ok := strings.CutPrefix(sc.Text(), "Z2K_GV_SUBST="); ok {
					v = strings.Trim(strings.TrimSpace(rest), `"'`)
				}
			}
			f.Close()
			if v == "0" {
				return false
			}
		}
	}
	return true
}

// localAddrs — адреса самого роутера.
func localAddrs() map[netip.Addr]bool {
	m := map[netip.Addr]bool{}
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if p, err := netip.ParsePrefix(a.String()); err == nil {
			m[p.Addr()] = true
		}
	}
	return m
}

// Run работает до отмены ctx. При выходе снимает свои подмены.
func Run(parent context.Context, cfg Config) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	q, err := OpenQueue(cfg.Queue)
	if err != nil {
		return err
	}
	rules := IPTables{Queue: strconv.Itoa(int(cfg.Queue)), NoV6: cfg.NoIPv6}
	var localMu sync.Mutex
	local := localAddrs()
	svc := &Service{Checker: NetChecker{}, Rules: rules, Resolver: &DNSResolver{}, StatusPath: cfg.StatusPath, IPFile: cfg.IPFile, Kill: func(f Flow) error {
		// Сначала правило сброса, потом удаление записи: повтор клиента
		// идёт уже мимо быстрого пути и получает RST.
		if err := rules.Reset(f); err != nil {
			return err
		}
		return DeleteFlow(f)
	},
		Local: func(a netip.Addr) bool { localMu.Lock(); defer localMu.Unlock(); return local[a] }}
	if _, err := rules.Ensure(); err != nil {
		log.Printf("gvsub: каркас правил: %v", err)
	}
	orphan := false
	// Порядок выхода: закрыть очередь, снять подмены. Ответы DNS не
	// придерживаются, ждать нечего.
	defer func() {
		q.Close()
		svc.Shutdown()
		if orphan {
			rules.Teardown() // init о нас не знает и каркас за нами не снимет
		}
	}()
	log.Printf("gvsub: очередь %d, слушаю ответы DNS", cfg.Queue)
	if n := svc.Restore(); n > 0 {
		log.Printf("gvsub: из прошлого запуска %d адресов в ходу, проверяю", n)
		go svc.Tick()
	}

	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)

	go func() {
		poll := time.NewTicker(PollEvery)
		recheck := time.NewTicker(RecheckEvery)
		defer poll.Stop()
		defer recheck.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-poll.C:
				l := localAddrs()
				localMu.Lock()
				local = l
				localMu.Unlock()
				if f, err := os.Open(cfg.Conntrack); err == nil {
					svc.OnConntrack(ParseConntrack(f))
					f.Close()
				}
			case <-recheck.C:
				if !wanted(cfg) {
					log.Printf("gvsub: init или конфиг службу больше не ведут — снимаю правила и выхожу")
					orphan = true
					cancel()
					return
				}
				svc.Tick()
			case <-hup:
				// Хук NDM шлёт сигнал сразу после пересборки таблицы, когда
				// цепочки может ещё не быть: сначала каркас, потом подмены.
				if _, err := rules.Ensure(); err != nil {
					log.Printf("gvsub: каркас правил: %v", err)
				}
				svc.Reapply()
			}
		}
	}()

	buf := make([]byte, 1<<17)
	fails := 0
	for ctx.Err() == nil {
		pkts, err := q.Read(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			// Разовая ошибка приёма не повод уходить: без службы ответы DNS
			// идут мимо (--queue-bypass), но и подмены перестают обновляться.
			fails++
			if fails > 100 {
				return err
			}
			log.Printf("gvsub: приём из очереди: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		fails = 0
		for _, p := range pkts {
			ans, ok := ParseReply(p.Payload)
			if !ok {
				_ = q.Accept(p.ID)
				continue
			}
			// Ответ не придерживается: проверка и подмена идут в фоне. Придержка
			// стоила каждому новому серверу видео до 2 с (проверка + поиск
			// соседа), Mac повторял запрос через 1 с, и шортс открывался ~10 с
			// (сбор 10.11.2026). Первое соединение к плохому адресу без подмены
			// ведёт проба z2k, следующие идут уже на соседа.
			svc.OnDNS(ans.Name, ans.Addrs)
			_ = q.Accept(p.ID)
		}
	}
	return nil
}
