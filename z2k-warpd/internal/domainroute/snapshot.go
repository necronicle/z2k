package domainroute

import (
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"time"
)

type snapshotEntry struct {
	Client, Dest, Name string
	Expiry             int64
}
type snapshotFile struct {
	Version int
	Entries []snapshotEntry
}

func (c *Cache) Save(path string) error {
	s := snapshotFile{Version: 1}
	for k, names := range c.pairs {
		for name, exp := range names {
			s.Entries = append(s.Entries, snapshotEntry{k.client.String(), k.dest.String(), name, exp.Unix()})
		}
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	if len(b) > 2<<20 {
		return errors.New("domain snapshot too large")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".pairs-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

func (c *Cache) Load(path string, now time.Time) error {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if len(b) > 2<<20 {
		return errors.New("domain snapshot too large")
	}
	var s snapshotFile
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	if s.Version != 1 || len(s.Entries) > maxJustifications {
		return errors.New("invalid domain snapshot")
	}
	c.pairs = make(map[pair]map[string]time.Time)
	for _, e := range s.Entries {
		client, ce := netip.ParseAddr(e.Client)
		dest, de := netip.ParseAddr(e.Dest)
		if ce != nil || de != nil || !EligibleDestination(dest) || !c.rules.Match(e.Name) || e.Expiry <= now.Unix() {
			continue
		}
		if c.global {
			if client != networkWide {
				continue
			}
		} else if _, err := clientSet(client); err != nil {
			continue
		}
		k := pair{client, dest}
		if _, ok := c.pairs[k]; !ok {
			if len(c.pairs) >= MaxPairs || (!c.hasClient(client) && c.clientCount() >= MaxClients) {
				c.skipped++
				continue
			}
			c.pairs[k] = make(map[string]time.Time)
		}
		c.pairs[k][e.Name] = time.Unix(e.Expiry, 0)
	}
	return nil
}
