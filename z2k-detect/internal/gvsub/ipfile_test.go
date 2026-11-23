package gvsub

import (
	"net/netip"
	"os"
	"strings"
	"testing"
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

func TestYouTubeCacheDoesNotPublishGVAddress(t *testing.T) {
	s, _, _, _ := newSvc()
	dir := t.TempDir()
	s.IPFile, s.StatusPath = dir+"/ips", dir+"/status"
	const name = "RR1---SN-EXAMPLE.C.YOUTUBE.COM."
	<-s.OnDNS(name, []netip.Addr{bad})
	s.writeStatus()
	restored, _, _, _ := newSvc()
	restored.IPFile, restored.StatusPath = s.IPFile, s.StatusPath
	if restored.Restore() != 1 {
		t.Fatal("expected DNS observation to survive restart")
	}
	restored.writeIPs()
	if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels {
		t.Fatalf("unexpected GV IP after YouTube DNS: %q (%v)", got, err)
	}
	<-s.OnDNS(gvName, []netip.Addr{bad})
	<-s.OnDNS(name, []netip.Addr{bad})
	if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels+bad.String()+"\n" {
		t.Fatalf("lost IP shared with googlevideo: %q (%v)", got, err)
	}
}

func TestSharedGFENotPublishedAndCheckNeutral(t *testing.T) {
	s, n, _, _ := newSvc()
	dir := t.TempDir()
	s.IPFile, s.StatusPath = dir+"/ips", dir+"/status"
	dead6 := netip.MustParseAddr("2a00:1450:4010:c02::c6")

	wait(t, s.OnDNS("redirector.googlevideo.com", []netip.Addr{bad}))
	wait(t, s.OnDNS("manifest.googlevideo.com", []netip.Addr{dead6}))

	if n.calls < 2 {
		t.Fatalf("expected Check() probes for SharedGFE addrs, calls=%d", n.calls)
	}
	if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels {
		t.Fatalf("SharedGFE polluted IPFile: %q (%v)", got, err)
	}
	nb, err := os.ReadFile(s.StatusPath + ".neutral")
	if err != nil || !strings.Contains(string(nb), "bad 4a7d6e46") || !strings.Contains(string(nb), "dead 2a00145040100c0200000000000000c6") {
		t.Fatalf("expected bad/dead neutral rows for SharedGFE, got=%q (%v)", nb, err)
	}
	s.writeStatus()

	// Эмулируем старый файл gv-ips.txt от предыдущей версии с уже попавшим туда redirector IP:
	// Restore() должен очистить SharedGFE-адрес и не добавлять их снова.
	if err := os.WriteFile(s.IPFile, []byte(ipFileSentinels+bad.String()+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	restored, _, _, _ := newSvc()
	restored.IPFile, restored.StatusPath = s.IPFile, s.StatusPath
	if restored.Restore() != 2 {
		t.Fatal("expected SharedGFE entries restored in known")
	}
	restored.writeIPs()
	if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels {
		t.Fatalf("Restore kept or added SharedGFE IP: %q (%v)", got, err)
	}
}

func TestSharedIPClusterAndRedirector(t *testing.T) {
	shared := netip.MustParseAddr("74.125.110.38")
	t.Run("cluster first then redirector", func(t *testing.T) {
		s, _, _, _ := newSvc()
		dir := t.TempDir()
		s.IPFile, s.StatusPath = dir+"/ips", dir+"/status"
		wait(t, s.OnDNS(gvName, []netip.Addr{shared}))
		wait(t, s.OnDNS("redirector.googlevideo.com", []netip.Addr{shared}))
		s.writeStatus()

		if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels+shared.String()+"\n" {
			t.Fatalf("shared cluster IP dropped after redirector: %q (%v)", got, err)
		}
		if err := os.Remove(s.IPFile); err != nil {
			t.Fatal(err)
		}
		restored, _, _, _ := newSvc()
		restored.IPFile, restored.StatusPath = s.IPFile, s.StatusPath
		if restored.Restore() != 1 {
			t.Fatal("expected restored known entry")
		}
		restored.writeIPs()
		if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels+shared.String()+"\n" {
			t.Fatalf("Restore lost shared cluster IP when redirector seen after cluster: %q (%v)", got, err)
		}
	})

	t.Run("redirector first then cluster", func(t *testing.T) {
		s, _, _, _ := newSvc()
		dir := t.TempDir()
		s.IPFile, s.StatusPath = dir+"/ips", dir+"/status"
		wait(t, s.OnDNS("redirector.googlevideo.com", []netip.Addr{shared}))
		if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels {
			t.Fatalf("redirector alone published IP: %q (%v)", got, err)
		}
		wait(t, s.OnDNS("rr2---sn-cache.gvt1.com", []netip.Addr{shared}))
		s.writeStatus()
		if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels+shared.String()+"\n" {
			t.Fatalf("cluster did not publish shared IP: %q (%v)", got, err)
		}
		restored, _, _, _ := newSvc()
		restored.IPFile, restored.StatusPath = s.IPFile, s.StatusPath
		restored.Restore()
		restored.writeIPs()
		if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels+shared.String()+"\n" {
			t.Fatalf("Restore lost cluster-promoted shared IP: %q (%v)", got, err)
		}
	})
}

func TestSharedIPYouTubeCacheAndRedirector(t *testing.T) {
	s, _, _, _ := newSvc()
	dir := t.TempDir()
	s.IPFile, s.StatusPath = dir+"/ips", dir+"/status"
	prov := netip.MustParseAddr("198.51.100.44")

	wait(t, s.OnDNS("rr1---sn-example.c.youtube.com", []netip.Addr{prov}))
	wait(t, s.OnDNS("redirector.googlevideo.com", []netip.Addr{prov}))

	if got, err := os.ReadFile(s.IPFile); err != nil || string(got) != ipFileSentinels {
		t.Fatalf("provider/SharedGFE polluted IPFile: %q (%v)", got, err)
	}
	nb, err := os.ReadFile(s.StatusPath + ".neutral")
	if err != nil || !strings.Contains(string(nb), "provider c633642c") {
		t.Fatalf("SharedGFE clobbered YouTubeCache provider marker: %q (%v)", nb, err)
	}
}
