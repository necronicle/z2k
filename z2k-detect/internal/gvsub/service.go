package gvsub

// DNS-наблюдение для обхода по ответу сервера.
// Адреса публикуются до освобождения DNS. Проверки готовности идут в фоне;
// переадресации, поиска соседей и сброса соединений здесь нет.
import (
	"bufio"
	"context"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	CacheTTL     = 60 * time.Second
	RecheckEvery = CacheTTL / 2
	ActiveFor    = 30 * time.Minute
	IdleDrop     = time.Hour
)

type entry struct {
	verdict       Verdict
	checked, seen time.Time
	name          string
}
type Service struct {
	Checker                       Checker
	Rules                         Rules
	Now                           func() time.Time
	StatusPath, IPFile, Whitelist string
	whitelist                     whitelist
	mu                            sync.Mutex
	published                     map[netip.Addr]struct{}
	known                         map[netip.Addr]*entry
	inflight                      map[netip.Addr]chan struct{}
	closed                        bool
	ipmu                          sync.Mutex
	ipLast                        string
	neutralMu                     sync.Mutex
	statusMu                      sync.Mutex
}

func (s *Service) init() {
	if s.known == nil {
		s.known = map[netip.Addr]*entry{}
		s.inflight = map[netip.Addr]chan struct{}{}
	}
	if s.published == nil {
		s.published = map[netip.Addr]struct{}{}
	}
	if s.Now == nil {
		s.Now = time.Now
	}
}
func (s *Service) OnDNS(name string, addrs []netip.Addr) <-chan struct{} {
	done := make(chan struct{})
	if !IsTarget(name) || s.whitelisted(name) {
		close(done)
		return done
	}
	s.mu.Lock()
	s.init()
	if s.closed {
		s.mu.Unlock()
		close(done)
		return done
	}
	now := s.Now()
	var waits []chan struct{}
	for _, a := range addrs {
		a = a.Unmap()
		if !a.IsValid() || !a.IsGlobalUnicast() {
			continue
		}
		if !providerCache(name, a) {
			s.published[a] = struct{}{}
		} else {
			delete(s.published, a)
		}
		e := s.known[a]
		if e == nil {
			e = &entry{}
			s.known[a] = e
		}
		e.seen, e.name = now, name
		// Provider answers themselves: neither preflight nor readiness probes.
		if isGoogle(a) && (e.checked.IsZero() || now.Sub(e.checked) >= CacheTTL) {
			waits = append(waits, s.startLocked(a))
		}
	}
	s.mu.Unlock()
	s.writeNeutral()
	s.writeIPs()
	go func() {
		for _, w := range waits {
			<-w
		}
		close(done)
	}()
	return done
}
func (s *Service) startLocked(a netip.Addr) chan struct{} {
	if ch := s.inflight[a]; ch != nil {
		return ch
	}
	ch := make(chan struct{})
	s.inflight[a] = ch
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), TCPTimeout+TLSTimeout)
		defer cancel()
		v := Unknown
		if s.Checker != nil {
			v = s.Checker.Check(ctx, a)
		}
		s.mu.Lock()
		if e := s.known[a]; e != nil && !s.closed {
			e.verdict, e.checked = v, s.Now()
		}
		delete(s.inflight, a)
		s.mu.Unlock()
		s.writeNeutral()
		s.writeStatus()
		close(ch)
	}()
	return ch
}
func (s *Service) Tick() {
	if s.Rules != nil {
		if _, err := s.Rules.Ensure(); err != nil {
			log.Printf("gvsub: DNS rules: %v", err)
		}
	}
	s.mu.Lock()
	s.init()
	now := s.Now()
	if !s.closed {
		for a, e := range s.known {
			if now.Sub(e.seen) > IdleDrop {
				delete(s.known, a)
				continue
			}
			if isGoogle(a) && now.Sub(e.seen) < ActiveFor && now.Sub(e.checked) >= RecheckEvery {
				s.startLocked(a)
			}
		}
	}
	s.mu.Unlock()
	s.writeNeutral()
	s.writeIPs()
	s.writeStatus()
}

// Bad remains useful to the strategy detectors: server-response filtering
// must not train a new SNI strategy. It no longer installs a QUIC reject.
func (s *Service) writeNeutral() {
	if s.StatusPath == "" {
		return
	}
	s.neutralMu.Lock()
	defer s.neutralMu.Unlock()
	s.mu.Lock()
	var rows []string
	if !s.closed {
		for a, e := range s.known {
			if providerCache(e.name, a) {
				rows = append(rows, "provider "+hex.EncodeToString(a.AsSlice()))
			}
			if e.verdict == Bad {
				rows = append(rows, "bad "+hex.EncodeToString(a.AsSlice()))
			}
		}
	}
	s.mu.Unlock()
	sort.Strings(rows)
	path := s.StatusPath + ".neutral"
	if os.WriteFile(path+".tmp", []byte(strings.Join(rows, "\n")+"\n"), 0644) == nil {
		_ = os.Rename(path+".tmp", path)
	}
}
func (s *Service) Shutdown() {
	s.mu.Lock()
	s.init()
	s.closed = true
	s.mu.Unlock()
	s.writeNeutral()
	s.writeStatus()
}

type statusFile struct {
	Updated time.Time   `json:"updated"`
	Known   int         `json:"known"`
	Bad     int         `json:"bad_seen"`
	Addrs   []knownAddr `json:"addrs,omitempty"`
}
type knownAddr struct {
	Addr string    `json:"addr"`
	Name string    `json:"name,omitempty"`
	Seen time.Time `json:"seen"`
}

func (s *Service) Restore() int {
	// Движок может жить дольше службы: не сужаем его набор при рестарте,
	// даже если status отсутствует или повреждён. Заглушки не входят в published.
	s.mu.Lock()
	s.init()
	if f, err := os.Open(s.IPFile); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if a, err := netip.ParseAddr(strings.TrimSpace(sc.Text())); err == nil && !a.IsUnspecified() && isGoogle(a) {
				s.published[a] = struct{}{}
			}
		}
		if err := sc.Err(); err != nil {
			log.Printf("gvsub: чтение списка адресов: %v", err)
		}
		f.Close()
	}
	s.mu.Unlock()
	if s.StatusPath == "" {
		return 0
	}
	b, err := os.ReadFile(s.StatusPath)
	if err != nil {
		return 0
	}
	var st statusFile
	if json.Unmarshal(b, &st) != nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.init()
	now := s.Now()
	n := 0
	for _, k := range st.Addrs {
		a, err := netip.ParseAddr(k.Addr)
		if err != nil || now.Sub(k.Seen) > IdleDrop || k.Seen.After(now) {
			continue
		}
		if s.known[a] == nil {
			s.known[a] = &entry{seen: k.Seen, name: k.Name}
			if !providerCache(k.Name, a) {
				s.published[a] = struct{}{}
			}
			n++
		}
	}
	return n
}

func (s *Service) writeStatus() {
	if s.StatusPath == "" {
		return
	}
	s.statusMu.Lock()
	defer s.statusMu.Unlock()
	s.mu.Lock()
	st := statusFile{Updated: s.Now(), Known: len(s.known)}
	for a, e := range s.known {
		if e.verdict == Bad {
			st.Bad++
		}
		st.Addrs = append(st.Addrs, knownAddr{Addr: a.String(), Name: e.name, Seen: e.seen})
	}
	s.mu.Unlock()
	sort.Slice(st.Addrs, func(i, j int) bool { return st.Addrs[i].Addr < st.Addrs[j].Addr })
	b, _ := json.MarshalIndent(st, "", "  ")
	tmp := s.StatusPath + ".tmp"
	if os.WriteFile(tmp, b, 0644) == nil {
		_ = os.Rename(tmp, s.StatusPath)
	}
}

const ipFileSentinels = "0.0.0.0/32\n::/128\n"

// writeIPs публикует накопительный набор, независимо от known.
// Удаление IP до ServerHello может увести поток из A и оборвать пробу.
// Поэтому не удаляем даже после IdleDrop или добавления имени в whitelist.
// Предела нет: ожидаются сотни адресов за аптайм; /tmp сбрасывает перезагрузка.
func (s *Service) writeIPs() {
	if s.IPFile == "" {
		return
	}
	s.ipmu.Lock()
	defer s.ipmu.Unlock()
	s.mu.Lock()
	list := make([]string, 0, len(s.published))
	for a := range s.published {
		list = append(list, a.String())
	}
	s.mu.Unlock()
	sort.Strings(list)
	body := ipFileSentinels
	if len(list) > 0 {
		body += strings.Join(list, "\n") + "\n"
	}
	if body == s.ipLast {
		// Файл могли удалить или обрезать снаружи: восстанавливаем снимок.
		if b, err := os.ReadFile(s.IPFile); err == nil && string(b) == body {
			return
		}
	}
	tmp := s.IPFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		log.Printf("gvsub: список адресов: %v", err)
		return
	}
	if err := os.Rename(tmp, s.IPFile); err != nil {
		log.Printf("gvsub: список адресов: %v", err)
		return
	}
	s.ipLast = body
}
