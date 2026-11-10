package gvsub

import (
	"compress/gzip"
	"context"
	"net/netip"
	"os"
	"testing"
	"time"
)

// Разные кластеры позволяют отличить проверки нового адреса и его соседей
// от досчёта запасных для уже опубликованного bad.
type whitelistResolver map[string][]netip.Addr

func (r whitelistResolver) Siblings(_ context.Context, cluster string, _ bool) []netip.Addr {
	return r[cluster]
}

func putWhitelist(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestWhitelistDNS(t *testing.T) {
	for _, q := range []string{gvName, "sub." + gvName, "SUB." + gvName + "."} {
		t.Run(q, func(t *testing.T) {
			s, n, r, _ := newSvc()
			s.IPFile, s.Whitelist = t.TempDir()+"/ips", t.TempDir()+"/whitelist"
			putWhitelist(t, s.Whitelist, " # комментарий\n; ещё\n/ комментарий\n\n RR1---SN-TEST.GOOGLEVIDEO.COM\tзаметка\n")
			s.writeIPs()
			wait(t, s.OnDNS(q, []netip.Addr{bad, netip.MustParseAddr("2a00:1450::1")}))
			s.Tick()
			got, err := os.ReadFile(s.IPFile)
			if err != nil || string(got) != ipFileSentinels {
				t.Fatalf("whitelist опубликован: %q, %v", got, err)
			}
			if n.calls != 0 || r.adds != 0 || r.rejects(bad) || len(s.known) != 0 {
				t.Fatal("whitelist вызвал проверку или подмену")
			}
		})
	}
}

func TestWhitelistReload(t *testing.T) {
	s, n, r, _ := newSvc()
	const otherName = "rr1---sn-list.googlevideo.com"
	other := netip.MustParseAddr("74.125.110.71")
	neighbors := []netip.Addr{netip.MustParseAddr("74.125.110.72"), netip.MustParseAddr("74.125.110.73")}
	s.Resolver = whitelistResolver{
		"sn-test": {netip.MustParseAddr("74.125.110.38"), netip.MustParseAddr("74.125.110.39"), netip.MustParseAddr("74.125.110.102")},
		"sn-list": neighbors,
	}
	for _, a := range neighbors {
		n.set(a.String(), Good)
	}
	s.IPFile, s.Whitelist = t.TempDir()+"/ips", t.TempDir()+"/whitelist"
	// Отсутствующий файл — пустой список.
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	if r.adds == 0 {
		t.Fatal("нет подмены без whitelist")
	}
	putWhitelist(t, s.Whitelist, otherName+"\n")
	// После добавления имени его новые адреса не публикуются; старый остаётся.
	wait(t, s.OnDNS(otherName, []netip.Addr{other}))
	got, _ := os.ReadFile(s.IPFile)
	if string(got) != ipFileSentinels+bad.String()+"\n" {
		t.Fatalf("изменился опубликованный набор: %q", got)
	}
	n.mu.Lock()
	checked := append([]netip.Addr(nil), n.checked...)
	n.mu.Unlock()
	for _, a := range checked {
		if a == other || a == neighbors[0] || a == neighbors[1] {
			t.Fatalf("whitelisted адрес или его сосед проверен: %s", a)
		}
	}
	// Только mtime: размер прежний, имя теперь не совпадает.
	st, err := os.Stat(s.Whitelist)
	if err != nil {
		t.Fatal(err)
	}
	putWhitelist(t, s.Whitelist, "xx1---sn-list.googlevideo.com\n")
	stamp := st.ModTime().Add(2 * time.Second)
	if err := os.Chtimes(s.Whitelist, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	wait(t, s.OnDNS(otherName, []netip.Addr{other}))
	if _, ok := s.known[other]; !ok {
		t.Fatal("mtime не подхвачен")
	}
	// Только размер: mtime прежний.
	putWhitelist(t, s.Whitelist, "googlevideo.com\n")
	if err := os.Chtimes(s.Whitelist, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	fresh := netip.MustParseAddr("74.125.110.200")
	wait(t, s.OnDNS(otherName, []netip.Addr{fresh}))
	if _, ok := s.known[fresh]; ok {
		t.Fatal("размер не подхвачен")
	}
	if err := os.Remove(s.Whitelist); err != nil {
		t.Fatal(err)
	}
	wait(t, s.OnDNS(otherName, []netip.Addr{fresh}))
	if _, ok := s.known[fresh]; !ok {
		t.Fatal("удаление файла не подхвачено")
	}
}

func TestWhitelistHostlistFormat(t *testing.T) {
	path := t.TempDir() + "/list" // gzip определяется по содержимому, не расширению.
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	z := gzip.NewWriter(f)
	_, err = z.Write([]byte("# ignored\r\n; ignored\n/ ignored\n\nGOOGLEVIDEO.COM\tcomment\n!except.googlevideo.com\n^only.example.com\n"))
	if err != nil {
		t.Fatal(err)
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	s := &Service{Whitelist: path}
	for q, want := range map[string]bool{
		"googlevideo.com": true, "Sub.Googlevideo.COM.": true,
		"notgooglevideo.com": false, "except.googlevideo.com": false,
		"sub.except.googlevideo.com": false, "only.example.com": true,
		"sub.only.example.com": false,
	} {
		if got := s.whitelisted(q); got != want {
			t.Errorf("%s = %v, нужно %v", q, got, want)
		}
	}
}

// Вопрос сохраняет клиентское имя, даже если вся цепочка CNAME уводит на другие имена.
func TestWhitelistCNAMEQuestion(t *testing.T) {
	for _, whitelistedQuestion := range []bool{true, false} {
		t.Run(map[bool]string{true: "question", false: "cname"}[whitelistedQuestion], func(t *testing.T) {
			q := gvName
			msg := dnsReply(q, rr{5, name("alias.googlevideo.com")}, rr{5, name("edge.example.net")}, rr{1, bad.AsSlice()})
			// Владельцы второй CNAME и конечной A соответствуют цепочке.
			off := 12 + len(name(q)) + 4
			off += 2 + 10 + len(name("alias.googlevideo.com"))
			msg = append(msg[:off], append(name("alias.googlevideo.com"), msg[off+2:]...)...)
			off += len(name("alias.googlevideo.com")) + 10 + len(name("edge.example.net"))
			msg = append(msg[:off], append(name("edge.example.net"), msg[off+2:]...)...)
			ans, ok := ParseReply(ipv4udp(msg))
			if !ok || ans.Name != q {
				t.Fatal("не разобран вопрос CNAME-цепочки")
			}
			s, _, r, _ := newSvc()
			s.IPFile, s.Whitelist = t.TempDir()+"/ips", t.TempDir()+"/whitelist"
			wl := "alias.googlevideo.com\nedge.example.net\n"
			if whitelistedQuestion {
				wl = q + "\n"
			}
			putWhitelist(t, s.Whitelist, wl)
			wait(t, s.OnDNS(ans.Name, ans.Addrs))
			got, _ := os.ReadFile(s.IPFile)
			if whitelistedQuestion {
				if len(got) != 0 || r.adds != 0 {
					t.Fatal("ответ для whitelist-вопроса затронут")
				}
			} else if r.adds == 0 {
				t.Fatal("CNAME ошибочно заменил имя вопроса при проверке whitelist")
			}
		})
	}
}
