package domainroute

import (
	"net/netip"
	"time"
)

const MaxPairs = 8192
const MaxClients = 128
const maxJustifications = 16384

type pair struct{ client, dest netip.Addr }
type Change struct {
	Client, Dest netip.Addr
	Expiry       time.Time
	Delete       bool
}
type Cache struct {
	rules          Rules
	pairs          map[pair]map[string]time.Time
	clients        map[netip.Addr]int
	justifications int
	skipped        uint64
}

func NewCache(r Rules) *Cache {
	return &Cache{
		rules:   r,
		pairs:   make(map[pair]map[string]time.Time),
		clients: make(map[netip.Addr]int),
	}
}
func (c *Cache) Len() int        { return len(c.pairs) }
func (c *Cache) Skipped() uint64 { return c.skipped }

func (c *Cache) decClient(client netip.Addr) {
	if c.clients[client] <= 1 {
		delete(c.clients, client)
	} else {
		c.clients[client]--
	}
}

func (c *Cache) deletePair(k pair) {
	if names, ok := c.pairs[k]; ok {
		c.justifications -= len(names)
		delete(c.pairs, k)
		c.decClient(k.client)
	}
}

func (c *Cache) Observe(client netip.Addr, name string, answers []Answer, now time.Time) []Change {
	if _, err := clientSet(client); err != nil || !c.rules.Match(name) {
		return nil
	}
	var changes []Change
	for _, a := range answers {
		if !EligibleDestination(a.IP) || a.TTL <= 0 {
			continue
		}
		k := pair{client, a.IP}
		_, exists := c.pairs[k][name]
		if !exists && c.justificationCount() >= maxJustifications {
			c.skipped++
			continue
		}
		if _, ok := c.pairs[k]; !ok {
			if len(c.pairs) >= MaxPairs || (!c.hasClient(client) && c.clientCount() >= MaxClients) {
				c.skipped++
				continue
			}
			c.pairs[k] = make(map[string]time.Time)
			c.clients[client]++
		}
		if !exists {
			c.justifications++
		}
		before := latest(c.pairs[k])
		ttl := min(a.TTL, time.Hour)
		c.pairs[k][name] = now.Add(ttl)
		after := latest(c.pairs[k])
		if !after.Equal(before) {
			changes = append(changes, Change{Client: client, Dest: a.IP, Expiry: after})
		}
	}
	return changes
}

func (c *Cache) hasClient(client netip.Addr) bool {
	return c.clients[client] > 0
}
func (c *Cache) clientCount() int {
	return len(c.clients)
}

func (c *Cache) justificationCount() int {
	return c.justifications
}

func latest(names map[string]time.Time) time.Time {
	var max time.Time
	for _, exp := range names {
		if exp.After(max) {
			max = exp
		}
	}
	return max
}

func (c *Cache) ReplaceRules(r Rules, now time.Time) []Change {
	c.rules = r
	return c.clean(now)
}
func (c *Cache) Expire(now time.Time) []Change { return c.clean(now) }

func (c *Cache) clean(now time.Time) []Change {
	var changes []Change
	for k, names := range c.pairs {
		before := latest(names)
		for name, exp := range names {
			if !exp.After(now) || !c.rules.Match(name) {
				delete(names, name)
				c.justifications--
			}
		}
		if len(names) == 0 {
			delete(c.pairs, k)
			c.decClient(k.client)
			changes = append(changes, Change{Client: k.client, Dest: k.dest, Delete: true})
		} else if after := latest(names); !after.Equal(before) {
			changes = append(changes, Change{Client: k.client, Dest: k.dest, Expiry: after})
		}
	}
	return changes
}

func (c *Cache) All(now time.Time) []Change {
	c.Expire(now)
	changes := make([]Change, 0, len(c.pairs))
	for k, names := range c.pairs {
		changes = append(changes, Change{Client: k.client, Dest: k.dest, Expiry: latest(names)})
	}
	return changes
}
