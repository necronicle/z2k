package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// Запрос обязан быть разбираемым любым резолвером: заголовок, один вопрос,
// метки с длиной впереди. Ошибка здесь не падает, а тихо даёт таймаут на
// каждом сервере — то есть выглядит как «все DNS мертвы».
func TestDNSQueryShape(t *testing.T) {
	q, err := dnsQuery(0xabcd, "example.com")
	if err != nil {
		t.Fatalf("dnsQuery: %v", err)
	}
	if got := binary.BigEndian.Uint16(q[0:2]); got != 0xabcd {
		t.Errorf("идентификатор: хотели 0xabcd, получили %#x", got)
	}
	if q[2]&0x01 == 0 {
		t.Error("не выставлен бит рекурсии (RD) — публичные резолверы ответят отказом")
	}
	if got := binary.BigEndian.Uint16(q[4:6]); got != 1 {
		t.Errorf("QDCOUNT: хотели 1, получили %d", got)
	}
	want := []byte{12: 7}
	_ = want
	if q[12] != 7 || string(q[13:20]) != "example" {
		t.Errorf("первая метка разложена неверно: % x", q[12:20])
	}
	if q[20] != 3 || string(q[21:24]) != "com" {
		t.Errorf("вторая метка разложена неверно: % x", q[20:24])
	}
	tail := q[len(q)-5:]
	if tail[0] != 0x00 || binary.BigEndian.Uint16(tail[1:3]) != 1 || binary.BigEndian.Uint16(tail[3:5]) != 1 {
		t.Errorf("хвост запроса: хотели 00 + QTYPE=A + QCLASS=IN, получили % x", tail)
	}
}

func TestDNSQueryRejectsGarbage(t *testing.T) {
	for _, name := range []string{"", "   ", "a..b"} {
		if _, err := dnsQuery(1, name); err == nil {
			t.Errorf("имя %q принято, а должно быть отвергнуто", name)
		}
	}
}

// Ответ с ЧУЖИМ идентификатором засчитываться не должен: на перехваченном
// UDP 53 посторонний пакет на наш порт — обычное дело, и он выдал бы
// молниеносное «время ответа» там, где сервер молчит.
func TestDNSRoundTripRejectsForeignID(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("нет локального UDP: %v", err)
	}
	defer pc.Close()
	go func() {
		buf := make([]byte, 512)
		n, addr, err := pc.ReadFrom(buf)
		if err != nil || n < 12 {
			return
		}
		reply := make([]byte, n)
		copy(reply, buf[:n])
		// Портим идентификатор — как если бы ответил не тот, кого спросили.
		binary.BigEndian.PutUint16(reply[0:2], binary.BigEndian.Uint16(reply[0:2])+1)
		_, _ = pc.WriteTo(reply, addr)
	}()

	ctx := context.Background()
	if _, err := dnsRoundTrip(ctx, pc.LocalAddr().String(), "example.com", 300*time.Millisecond); err == nil {
		t.Error("чужой идентификатор засчитан за ответ")
	}
}

// Свой идентификатор — ответ принимается, число осмысленное.
func TestDNSRoundTripMeasures(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("нет локального UDP: %v", err)
	}
	defer pc.Close()
	go func() {
		buf := make([]byte, 512)
		n, addr, err := pc.ReadFrom(buf)
		if err != nil || n < 12 {
			return
		}
		time.Sleep(20 * time.Millisecond)
		_, _ = pc.WriteTo(buf[:n], addr)
	}()

	ms, err := dnsRoundTrip(context.Background(), pc.LocalAddr().String(), "example.com", time.Second)
	if err != nil {
		t.Fatalf("dnsRoundTrip: %v", err)
	}
	if ms < 15 || ms > 500 {
		t.Errorf("время ответа вне разумного: %d мс (ждали около 20)", ms)
	}
}

// Молчащий сервер обязан кончиться таймаутом, а не висеть: вызов стоит в цикле
// по семи серверам, и один молчащий не должен вешать всю проверку.
func TestDNSRoundTripTimesOut(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("нет локального UDP: %v", err)
	}
	defer pc.Close() // никто не отвечает

	start := time.Now()
	if _, err := dnsRoundTrip(context.Background(), pc.LocalAddr().String(), "example.com", 200*time.Millisecond); err == nil {
		t.Error("молчащий сервер засчитан за ответивший")
	}
	if el := time.Since(start); el > 2*time.Second {
		t.Errorf("таймаут не сработал: ждали 200 мс, вышло %v", el)
	}
}

func TestNormalizeHostPortIPv6(t *testing.T) {
	cases := map[string]string{
		"1.1.1.1":                "1.1.1.1:53",
		"2001:4860:4860::8888":   "[2001:4860:4860::8888]:53",
		"[2001:4860:4860::8888]": "[2001:4860:4860::8888]:53",
		"fe80::1%br0":            "[fe80::1%br0]:53",
		"[::1]:5353":             "[::1]:5353",
	}
	for in, want := range cases {
		if got := normalizeHostPort(in, "53"); got != want {
			t.Errorf("normalizeHostPort(%q): хотели %q, получили %q", in, want, got)
		}
	}
}

func TestDNSRoundTripIPv6(t *testing.T) {
	pc, err := net.ListenPacket("udp6", "[::1]:0")
	if err != nil {
		t.Skipf("нет локального UDPv6: %v", err)
	}
	defer pc.Close()
	go func() {
		buf := make([]byte, 512)
		n, addr, err := pc.ReadFrom(buf)
		if err != nil || n < 12 {
			return
		}
		_, _ = pc.WriteTo(buf[:n], addr)
	}()
	ms, err := dnsRoundTrip(context.Background(), pc.LocalAddr().String(), "example.com", time.Second)
	if err != nil || ms < 1 {
		t.Fatalf("dnsRoundTrip IPv6: ms=%d err=%v", ms, err)
	}
}

func buildTestDoTCerts(t *testing.T) (caFile string, srvCert tls.Certificate) {
	t.Helper()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caTpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "z2k test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTpl, caTpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leafTpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "dns.example"},
		DNSNames:     []string{"dns.example"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTpl, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}

	caFile = filepath.Join(t.TempDir(), "ca.pem")
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	if err := os.WriteFile(caFile, caPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	return caFile, tls.Certificate{
		Certificate: [][]byte{leafDER},
		PrivateKey:  leafKey,
	}
}

func makeFakeDNSReply(q []byte, rcode byte, ips ...net.IP) []byte {
	out := make([]byte, len(q))
	copy(out, q)
	out[2] = 0x81
	out[3] = 0x80 | (rcode & 0x0f)
	binary.BigEndian.PutUint16(out[6:8], uint16(len(ips)))
	for _, ip := range ips {
		v4 := ip.To4()
		rr := make([]byte, 16)
		rr[0], rr[1] = 0xc0, 0x0c // указатель на имя вопроса
		binary.BigEndian.PutUint16(rr[2:4], 1)
		binary.BigEndian.PutUint16(rr[4:6], 1)
		binary.BigEndian.PutUint32(rr[6:10], 60)
		binary.BigEndian.PutUint16(rr[10:12], 4)
		copy(rr[12:16], v4)
		out = append(out, rr...)
	}
	return out
}

func decodeQName(pkt []byte) string {
	p := 12
	var parts []string
	for p < len(pkt) && pkt[p] != 0 {
		l := int(pkt[p])
		p++
		if p+l > len(pkt) {
			break
		}
		parts = append(parts, string(pkt[p:p+l]))
		p += l
	}
	res := ""
	for i, s := range parts {
		if i > 0 {
			res += "."
		}
		res += s
	}
	return res
}

func TestDNSDoTBatchPipelinedAndCertChecks(t *testing.T) {
	caFile, srvCert := buildTestDoTCerts(t)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{srvCert}})
	if err != nil {
		t.Skipf("нет локального TCP: %v", err)
	}
	defer ln.Close()

	var conns atomic.Int32
	go func() {
		for {
			c, aerr := ln.Accept()
			if aerr != nil {
				return
			}
			conns.Add(1)
			go func(conn net.Conn) {
				defer conn.Close()
				// Первый запрос — контрольный.
				q0, rerr := readDoTFrame(conn)
				if rerr != nil {
					return
				}
				_ = writeDoTFrame(conn, makeFakeDNSReply(q0, 0, net.IPv4(93, 184, 216, 34)))

				// Следующие 3 запроса читаем пачкой и отдаём В ОБРАТНОМ порядке
				// (проверка RFC 7858 §3.3 out-of-order pipelining).
				var qs [][]byte
				for i := 0; i < 3; i++ {
					q, err2 := readDoTFrame(conn)
					if err2 != nil {
						return
					}
					qs = append(qs, q)
				}
				for i := len(qs) - 1; i >= 0; i-- {
					q := qs[i]
					switch decodeQName(q) {
					case "rutor.info":
						_ = writeDoTFrame(conn, makeFakeDNSReply(q, 0, net.IPv4(198, 51, 100, 20), net.IPv4(198, 51, 100, 10)))
					case "nx.example":
						_ = writeDoTFrame(conn, makeFakeDNSReply(q, 3)) // NXDOMAIN
					case "api.github.com":
						_ = writeDoTFrame(conn, makeFakeDNSReply(q, 0, net.IPv4(140, 82, 121, 6)))
					}
				}
			}(c)
		}
	}()

	items := []dotItem{
		{purpose: "target", domain: "rutor.info"},
		{purpose: "control", domain: "example.com"},
		{purpose: "target", domain: "nx.example"},
		{purpose: "proxy", domain: "api.github.com"},
	}
	ms, res, err := dnsDoTBatch(context.Background(), "dns.example", ln.Addr().String(), caFile, 2*time.Second, items)
	if err != nil {
		t.Fatalf("dnsDoTBatch: %v", err)
	}
	if ms < 1 {
		t.Errorf("ожидалось ms >= 1, получено %d", ms)
	}
	if got := conns.Load(); got != 1 {
		t.Errorf("все 4 вопроса должны пройти за 1 TLS-соединение, открыто %d", got)
	}
	if res[0].outcome != "addresses" || len(res[0].addrs) != 2 || res[0].addrs[0] != "198.51.100.10" {
		t.Errorf("rutor.info: неверный разбор/сортировка: %+v", res[0])
	}
	if res[1].outcome != "addresses" || res[1].addrs[0] != "93.184.216.34" {
		t.Errorf("example.com: %+v", res[1])
	}
	if res[2].outcome != "no_a" || len(res[2].addrs) != 0 {
		t.Errorf("nx.example (NXDOMAIN) должен дать no_a, получено: %+v", res[2])
	}
	if res[3].outcome != "addresses" || res[3].addrs[0] != "140.82.121.6" {
		t.Errorf("api.github.com: %+v", res[3])
	}

	// Проверка по IP SAN (127.0.0.1) тоже обязана проходить, а чужое имя — падать.
	if _, _, err := dnsDoTBatch(context.Background(), "127.0.0.1", ln.Addr().String(), caFile, time.Second, items[:2]); err != nil {
		t.Errorf("проверка по IP SAN 127.0.0.1 не прошла: %v", err)
	}
	if _, _, err := dnsDoTBatch(context.Background(), "wrong.example", ln.Addr().String(), caFile, time.Second, items[:1]); err == nil {
		t.Error("чужое имя хоста прошло проверку сертификата")
	}
	emptyCA := filepath.Join(t.TempDir(), "empty.pem")
	_ = os.WriteFile(emptyCA, []byte("not a cert"), 0o600)
	if _, _, err := dnsDoTBatch(context.Background(), "dns.example", ln.Addr().String(), emptyCA, time.Second, items[:1]); !errors.Is(err, errNoVerifyRoots) {
		t.Errorf("пустой CA должен вернуть errNoVerifyRoots, получено: %v", err)
	}
}

func TestDNSDoTBatchEnforcesOverallTimeoutAndNoControlMs(t *testing.T) {
	caFile, srvCert := buildTestDoTCerts(t)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{srvCert}})
	if err != nil {
		t.Skipf("нет локального TCP: %v", err)
	}
	defer ln.Close()

	var conns atomic.Int32
	go func() {
		for {
			c, aerr := ln.Accept()
			if aerr != nil {
				return
			}
			n := conns.Add(1)
			go func(conn net.Conn, seq int32) {
				defer conn.Close()
				q0, rerr := readDoTFrame(conn)
				if rerr != nil {
					return
				}
				if seq == 1 {
					// Первый вызов: отвечаем NXDOMAIN на контроль и сразу закрываем,
					// а на резервных соединениях молчим до дедлайна.
					_ = writeDoTFrame(conn, makeFakeDNSReply(q0, 3))
					return
				}
				// Зависаем без ответа до закрытия клиентом по общему дедлайну.
				time.Sleep(2 * time.Second)
			}(c, n)
		}
	}()

	items := []dotItem{
		{purpose: "control", domain: "example.com"},
		{purpose: "target", domain: "d1.example"},
		{purpose: "target", domain: "d2.example"},
		{purpose: "target", domain: "d3.example"},
		{purpose: "target", domain: "d4.example"},
		{purpose: "target", domain: "d5.example"},
	}
	start := time.Now()
	ms, res, err := dnsDoTBatch(context.Background(), "dns.example", ln.Addr().String(), caFile, 250*time.Millisecond, items)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("dnsDoTBatch: %v", err)
	}
	if ms != 0 {
		t.Errorf("при ответе контроля без A задержка ms не должна публиковаться, получено %d", ms)
	}
	if res[0].outcome != "no_a" {
		t.Errorf("ожидался no_a на контроле, получено %+v", res[0])
	}
	if elapsed > 900*time.Millisecond {
		t.Errorf("общий потолок 250 мс нарушен каскадом допросов: заняло %v (соединений %d)", elapsed, conns.Load())
	}
}

func TestDialDoTRejectsSelfSignedUnderOnlyFallback(t *testing.T) {
	// Пул содержит только сторонний корень (имитация единственного z2k-roots.pem).
	otherCAFile, _ := buildTestDoTCerts(t)
	otherPEM, err := os.ReadFile(otherCAFile)
	if err != nil {
		t.Fatal(err)
	}
	fallbackPool := x509.NewCertPool()
	if !fallbackPool.AppendCertsFromPEM(otherPEM) {
		t.Fatal("не загрузился тестовый пул")
	}

	// 1. Сертификат, подписанный неизвестным внешним CA (Issuer != Subject) -> errNoVerifyRoots.
	_, caSignedLeaf := buildTestDoTCerts(t)
	lnCA, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{caSignedLeaf}})
	if err != nil {
		t.Skipf("нет локального TCP: %v", err)
	}
	defer lnCA.Close()
	go func() {
		for {
			c, aerr := lnCA.Accept()
			if aerr != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_ = conn.(*tls.Conn).Handshake()
			}(c)
		}
	}()
	_, err = dialDoT(context.Background(), lnCA.Addr().String(), "dns.example", fallbackPool, true, time.Second)
	if !errors.Is(err, errNoVerifyRoots) {
		t.Errorf("сертификат неизвестного CA при onlyFallback должен давать errNoVerifyRoots, получено: %v", err)
	}

	// 2. Самоподписанный leaf-сертификат (Issuer == Subject) -> обычная ошибка верификации, НЕ errNoVerifyRoots.
	ssKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ssTpl := &x509.Certificate{
		SerialNumber: big.NewInt(99),
		Subject:      pkix.Name{CommonName: "dns.example"},
		DNSNames:     []string{"dns.example"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	ssDER, err := x509.CreateCertificate(rand.Reader, ssTpl, ssTpl, &ssKey.PublicKey, ssKey)
	if err != nil {
		t.Fatal(err)
	}
	ssCert := tls.Certificate{Certificate: [][]byte{ssDER}, PrivateKey: ssKey}
	lnSS, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{ssCert}})
	if err != nil {
		t.Fatal(err)
	}
	defer lnSS.Close()
	go func() {
		for {
			c, aerr := lnSS.Accept()
			if aerr != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_ = conn.(*tls.Conn).Handshake()
			}(c)
		}
	}()
	_, err = dialDoT(context.Background(), lnSS.Addr().String(), "dns.example", fallbackPool, true, time.Second)
	if err == nil || errors.Is(err, errNoVerifyRoots) {
		t.Errorf("самоподписанный leaf при onlyFallback обязан отклоняться как ошибка сертификата, получено: %v", err)
	}
}
