package domainroute

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type Status struct {
	Active   bool   `json:"active"`
	Rules    int    `json:"rules"`
	Pairs    int    `json:"pairs"`
	Skipped  uint64 `json:"skipped"`
	Overflow uint64 `json:"overflow"`
	Error    string `json:"error,omitempty"`
}

type Options struct {
	DomainPath, SnapshotPath, StatusPath string
	PairSet                              PairSet
}

var ErrObserverAlreadyRunning = errors.New("domain observer is already running")

type Observer struct {
	mu        sync.Mutex
	decoder   *PacketDecoder
	cache     *Cache
	local     map[netip.Addr]struct{}
	active    bool
	overflow  uint64
	lastError string
}

func NewObserver(r Rules) *Observer {
	return &Observer{decoder: NewPacketDecoder(), cache: NewCache(r), local: make(map[netip.Addr]struct{})}
}

func (o *Observer) SetLocalAddresses(addresses []netip.Addr) []Change {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.local = make(map[netip.Addr]struct{}, len(addresses))
	for _, ip := range addresses {
		if ip.Is4() {
			o.local[ip] = struct{}{}
		}
	}
	var changes []Change
	for k := range o.cache.pairs {
		if _, owned := o.local[k.dest]; owned {
			o.cache.deletePair(k)
			changes = append(changes, Change{Client: k.client, Dest: k.dest, Delete: true})
		}
	}
	return changes
}

func routerAddresses() []netip.Addr {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	result := make([]netip.Addr, 0, len(addrs))
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		if ip, ok := netip.AddrFromSlice(ipnet.IP); ok {
			result = append(result, ip.Unmap())
		}
	}
	return result
}

func (o *Observer) Process(packet []byte, now time.Time) []Change {
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(packet) > maxDNSFrame+60 {
		o.overflow++
		return nil
	}
	client, payload, transport := o.decoder.Push(packet, now)
	if !client.IsValid() || len(payload) == 0 {
		return nil
	}
	name, answers, err := ParseReply(payload, transport)
	if err != nil {
		return nil
	}
	filtered := answers[:0]
	for _, answer := range answers {
		if _, local := o.local[answer.IP]; !local {
			filtered = append(filtered, answer)
		}
	}
	return o.cache.Observe(client, name, filtered, now)
}

func (o *Observer) ReplaceRules(r Rules, now time.Time) []Change {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.cache.ReplaceRules(r, now)
}

func (o *Observer) status() Status {
	o.mu.Lock()
	defer o.mu.Unlock()
	return Status{Active: o.active, Rules: o.cache.rules.Len(), Pairs: o.cache.Len(), Skipped: o.cache.Skipped(), Overflow: o.overflow, Error: o.lastError}
}

func (o *Observer) setState(active bool, err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.active = active
	if err == nil {
		o.lastError = ""
	} else {
		o.lastError = err.Error()
	}
}

func writeStatus(path string, s Status) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (o *Observer) Run(ctx context.Context, opts Options) error {
	if opts.DomainPath == "" || opts.SnapshotPath == "" || opts.StatusPath == "" {
		return errors.New("missing observer path")
	}
	if err := os.MkdirAll(filepath.Dir(opts.StatusPath), 0700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(filepath.Dir(opts.StatusPath), "observer.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return ErrObserverAlreadyRunning
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	data, err := os.ReadFile(opts.DomainPath)
	if err != nil {
		o.setState(false, err)
		_ = writeStatus(opts.StatusPath, o.status())
		return err
	}
	rules, err := ParseRules(data)
	if err != nil {
		o.setState(false, err)
		_ = writeStatus(opts.StatusPath, o.status())
		return err
	}
	o.ReplaceRules(rules, time.Now())
	o.SetLocalAddresses(routerAddresses())
	o.mu.Lock()
	err = o.cache.Load(opts.SnapshotPath, time.Now())
	o.mu.Unlock()
	o.SetLocalAddresses(routerAddresses())
	o.mu.Lock()
	initial := o.cache.All(time.Now())
	o.mu.Unlock()
	if err != nil {
		// A corrupt tmpfs snapshot must not disable fresh DNS learning.
		o.setState(false, err)
	}
	var kernelMu sync.Mutex
	needReconcile := false
	apply := func(changes []Change) {
		kernelMu.Lock()
		defer kernelMu.Unlock()
		if err := opts.PairSet.Apply(changes, time.Now()); err != nil {
			needReconcile = true
			o.setState(false, err)
		}
	}
	reconcile := func(changes []Change) {
		kernelMu.Lock()
		defer kernelMu.Unlock()
		if err := opts.PairSet.ReplaceAll(changes, time.Now()); err != nil {
			needReconcile = true
			o.setState(false, err)
		} else {
			needReconcile = false
			o.setState(true, nil)
		}
	}
	reconcile(initial)
	stop, err := receivePackets(ctx, func(packet []byte) { apply(o.Process(packet, time.Now())) }, func(err error) { o.setState(false, err) })
	if err != nil {
		o.setState(false, err)
		_ = writeStatus(opts.StatusPath, o.status())
		return err
	}
	defer stop()
	kernelMu.Lock()
	pending := needReconcile
	kernelMu.Unlock()
	if !pending {
		o.setState(true, nil)
	}
	_ = writeStatus(opts.StatusPath, o.status())
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	lastSave := time.Now()
	for {
		select {
		case <-ctx.Done():
			o.mu.Lock()
			err := o.cache.Save(opts.SnapshotPath)
			o.mu.Unlock()
			o.setState(false, err)
			_ = writeStatus(opts.StatusPath, o.status())
			return nil
		case now := <-tick.C:
			apply(o.SetLocalAddresses(routerAddresses()))
			rulesOK := false
			if data, err := os.ReadFile(opts.DomainPath); err == nil {
				if next, err := ParseRules(data); err == nil {
					apply(o.ReplaceRules(next, now))
					rulesOK = true
				} else {
					o.setState(false, err)
				}
			} else {
				o.setState(false, err)
			}
			o.mu.Lock()
			changes := o.cache.Expire(now)
			all := o.cache.All(now)
			if now.Sub(lastSave) >= 15*time.Second {
				_ = o.cache.Save(opts.SnapshotPath)
				lastSave = now
			}
			o.mu.Unlock()
			apply(changes)
			kernelMu.Lock()
			pending := needReconcile
			kernelMu.Unlock()
			if pending {
				reconcile(all)
			} else {
				apply(all)
				kernelMu.Lock()
				stillPending := needReconcile
				kernelMu.Unlock()
				if rulesOK && !stillPending {
					o.setState(true, nil)
				}
			}
			_ = writeStatus(opts.StatusPath, o.status())
		}
	}
}
