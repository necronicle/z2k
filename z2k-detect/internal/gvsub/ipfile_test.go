package gvsub

import (
	"net/netip"
	"os"
	"testing"
	"time"
)

func TestWriteIPsSentinels(t *testing.T) {
	for _, populated := range []bool{false, true} {
		t.Run(map[bool]string{false: "empty", true: "addresses"}[populated], func(t *testing.T) {
			s := &Service{IPFile: t.TempDir() + "/ips"}
			want := "0.0.0.0/32\n::/128\n"
			if populated {
				s.published = map[netip.Addr]struct{}{netip.MustParseAddr("1.1.1.1"): {}, netip.MustParseAddr("2606:4700::1111"): {}}
				want += "1.1.1.1\n2606:4700::1111\n"
			}
			for _, damage := range []string{"initial", "remove", "truncate"} {
				switch damage {
				case "remove":
					if err := os.Remove(s.IPFile); err != nil {
						t.Fatal(err)
					}
				case "truncate":
					if err := os.WriteFile(s.IPFile, nil, 0644); err != nil {
						t.Fatal(err)
					}
				}
				s.writeIPs()
				got, err := os.ReadFile(s.IPFile)
				if err != nil || string(got) != want {
					t.Fatalf("%s: got %q, err %v, want %q", damage, got, err, want)
				}
			}
		})
	}
}

// Перезапуск при живом движке сохраняет даже адреса, уже забытые status.
func TestIPFileRestoreUnion(t *testing.T) {
	for _, status := range []string{"disabled", "missing", "corrupt", "valid"} {
		t.Run(status, func(t *testing.T) {
			s, _, _, c := newSvc()
			dir := t.TempDir()
			s.IPFile, s.StatusPath = dir+"/ips", dir+"/status"
			old := "2a00:1450::1"
			if err := os.WriteFile(s.IPFile, []byte(ipFileSentinels+old+"\n"), 0600); err != nil {
				t.Fatal(err)
			}
			if status == "valid" {
				previous, _, _, _ := newSvc()
				previous.StatusPath = s.StatusPath
				previous.init()
				previous.known[bad] = &entry{seen: c.now(), name: gvName}
				previous.writeStatus()
			} else if status == "corrupt" {
				if err := os.WriteFile(s.StatusPath, []byte("broken"), 0600); err != nil {
					t.Fatal(err)
				}
			} else if status == "disabled" {
				s.StatusPath = ""
			}
			n := s.Restore()
			s.writeIPs()
			want := ipFileSentinels + old + "\n"
			if status == "valid" {
				want += bad.String() + "\n"
				if n != 1 {
					t.Fatalf("Restore=%d", n)
				}
			}
			got, err := os.ReadFile(s.IPFile)
			if err != nil || string(got) != want {
				t.Fatalf("Restore сузил набор: %q, %v; нужен %q", got, err, want)
			}
			s.mu.Lock()
			_, exists := s.known[netip.MustParseAddr(old)]
			s.mu.Unlock()
			if exists {
				t.Fatal("старый опубликованный адрес попал в known")
			}
		})
	}
}

func TestIPFileIdleDropMapping(t *testing.T) {
	s, _, r, c := newSvc()
	s.IPFile = t.TempDir() + "/ips"
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	if len(s.Mappings()) == 0 {
		t.Fatal("не поставлена исходная подмена")
	}
	c.add(IdleDrop + time.Second)
	s.Tick()
	s.mu.Lock()
	_, known := s.known[bad]
	s.mu.Unlock()
	if known || len(s.Mappings()) != 0 || r.rejects(bad) {
		t.Fatal("IdleDrop не убрал known/подмену/QUIC")
	}
	got, err := os.ReadFile(s.IPFile)
	if err != nil || string(got) != ipFileSentinels+bad.String()+"\n" {
		t.Fatalf("IdleDrop сузил IPFile: %q, %v", got, err)
	}
}
