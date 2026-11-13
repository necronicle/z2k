package gvsub

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Config — параметры запуска службы.
type Config struct {
	Queue      uint16 // очередь с ответами DNS
	StatusPath string
	NoIPv6     bool // IPv6 выключен в z2k
	// Owner — init-скрипт, который запускает службу, и ConfigPath — конфиг z2k.
	// Служба уходит сама и снимает свой каркас, если init её больше не знает
	// (ночное обновление 10.11.2026 вернуло init без неё, а служба осталась
	// держать ответы DNS) или обход по ответу сервера выключен в конфиге.
	Owner      string
	ConfigPath string
	// IPFile — адреса googlevideo из ответов DNS, для профиля движка с --ipset.
	IPFile    string
	Whitelist string // путь к hostlist исключений, перечитывается при изменении
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
		return serverReplyConfigured(cfg.ConfigPath)
	}

	return true
}

// Run работает до отмены ctx. При выходе снимает свои правила.
func Run(parent context.Context, cfg Config) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	q, err := OpenQueue(cfg.Queue)
	if err != nil {
		return err
	}
	rules := IPTables{Queue: strconv.Itoa(int(cfg.Queue)), NoV6: cfg.NoIPv6}
	svc := &Service{Checker: NetChecker{}, Rules: rules, StatusPath: cfg.StatusPath, IPFile: cfg.IPFile, Whitelist: cfg.Whitelist}
	// Remove obsolete hooks before accepting DNS after an upgrade.
	rules.Teardown()

	if _, err := rules.Ensure(); err != nil {
		log.Printf("gvsub: каркас правил: %v", err)
	}
	orphan := false
	// Порядок выхода: закрыть очередь, снять правила. Ответы DNS не
	// придерживаются, ждать нечего.
	defer func() {
		q.Close()
		svc.Shutdown()
		if orphan {
			rules.Teardown() // init о нас не знает и каркас за нами не снимет
		}
	}()
	log.Printf("gvsub: очередь %d, слушаю ответы DNS", cfg.Queue)
	n := svc.Restore()
	// Первый снимок, включая пустой known, публикуем до освобождения DNS.
	svc.writeNeutral()
	svc.writeIPs()
	if n > 0 {
		log.Printf("gvsub: из прошлого запуска %d адресов в ходу, проверяю", n)
		go svc.Tick()
	}

	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)

	go func() {
		recheck := time.NewTicker(RecheckEvery)
		defer recheck.Stop()
		for {
			select {
			case <-ctx.Done():
				return
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
				// цепочки может ещё не быть: сначала каркас, потом правила.
				if _, err := rules.Ensure(); err != nil {
					log.Printf("gvsub: каркас правил: %v", err)
				}
				svc.writeNeutral()
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
			// идут мимо (--queue-bypass), но и правила перестают обновляться.
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
			// IP-файл опубликован синхронно; проверка готовности идёт в фоне.
			svc.OnDNS(ans.Name, ans.Addrs)
			_ = q.Accept(p.ID)
		}
	}
	return nil
}
