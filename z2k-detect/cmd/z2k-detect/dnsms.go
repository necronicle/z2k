package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

var errNoVerifyRoots = errors.New("нет корневых сертификатов для проверки TLS")

// dnsmsCmd — сколько миллисекунд занимает обычный UDP-запрос к DNS-серверу.
//
// ЗАЧЕМ ОТДЕЛЬНАЯ КОМАНДА. Время обычного DNS в панели показывалось только там,
// где установлен пакет bind-dig: он один печатает «;; Query time: N msec».
// Пакет тянет за собой bind-libs — 2,4 МБ на флешке ради одного числа, и стоит
// далеко не у всех, поэтому у половины людей строки «Обычный DNS» были без
// времени, а DoH и DoT рядом — с временем (жалоба 16.09.2026).
//
// Оболочкой это не меряется: дробного sleep у busybox нет, `date +%s%N`
// печатает literal %N, а `nc -u` в их сборке отсутствует вовсе (проверено на
// роутере). Счётчик usleep с шагом 10 мс, которым меряется DoT, здесь не
// подходит: обычный запрос укладывается в единицы миллисекунд, и шаг в 10 мс
// огрубил бы его до неразличимости.
//
// Го здесь уже установлен на каждом роутере: z2k-detect возит проба блока по
// объёму и подбор стратегий. Команда добавляет к нему сорок строк и ни одного
// нового пакета.
//
// Замеряется ровно обмен: сокет создан заранее, таймер вокруг WriteTo/ReadFrom.
func dnsmsCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("dnsms", flag.ExitOnError)
	server := fs.String("server", "", "адрес DNS-сервера")
	name := fs.String("name", "example.com", "какое имя спрашивать")
	timeout := fs.Duration("timeout", 2*time.Second, "потолок ожидания")
	_ = fs.Parse(rest)

	if *server == "" {
		fatal("нужен -server")
	}
	ms, err := dnsRoundTrip(ctx, *server, *name, *timeout)
	if err != nil {
		// Молчащий сервер — не ошибка запуска: вызывающая оболочка отличает
		// «нет ответа» от «нет команды» по коду возврата, а не по тексту.
		fmt.Fprintf(os.Stderr, "нет ответа от %s: %v\n", *server, err)
		os.Exit(1)
	}
	fmt.Println(ms)
}

// normalizeHostPort приводит IPv4, IPv6 (со скобками или без, в т.ч. с %iface)
// и host:port к виду, пригодному для net.Dialer.
func normalizeHostPort(server, defaultPort string) string {
	server = strings.TrimSpace(server)
	if _, _, err := net.SplitHostPort(server); err == nil {
		return server
	}
	clean := strings.TrimSuffix(strings.TrimPrefix(server, "["), "]")
	return net.JoinHostPort(clean, defaultPort)
}

// dnsRoundTrip — один запрос A-записи и ответ на него, в миллисекундах.
func dnsRoundTrip(ctx context.Context, server, name string, timeout time.Duration) (int64, error) {
	host := normalizeHostPort(server, "53")
	var d net.Dialer
	conn, err := d.DialContext(ctx, "udp", host)
	if err != nil {
		return 0, err
	}
	defer conn.Close()

	// Идентификатор случайный: два подряд одинаковых запроса иначе рискуют
	// склеиться на кэширующем резолвере и второй замер покажет ноль.
	q, err := dnsQuery(uint16(rand.Intn(0xffff)), name)
	if err != nil {
		return 0, err
	}
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return 0, err
	}

	start := time.Now()
	if _, err := conn.Write(q); err != nil {
		return 0, err
	}
	buf := make([]byte, 1500)
	n, err := conn.Read(buf)
	if err != nil {
		return 0, err
	}
	elapsed := time.Since(start)
	if n < 12 {
		return 0, fmt.Errorf("ответ короче заголовка: %d байт", n)
	}
	// Ответ обязан быть НА НАШ запрос: чужой пакет на том же порту (а на
	// перехваченном UDP 53 это обычное дело) иначе засчитался бы за ответ.
	if binary.BigEndian.Uint16(buf[:2]) != binary.BigEndian.Uint16(q[:2]) {
		return 0, fmt.Errorf("чужой идентификатор в ответе")
	}
	ms := elapsed.Milliseconds()
	if ms < 1 {
		ms = 1 // ноль миллисекунд человеку ничего не говорит и выглядит поломкой
	}
	return ms, nil
}

// dotItem — один вопрос для проверки DNS over TLS (RFC 7858).
type dotItem struct {
	purpose string
	domain  string
}

type dotResult struct {
	purpose string
	domain  string
	outcome string
	addrs   []string
}

// dnsdotCmd опрашивает список доменов по DoT (порт 853) через одно проверенное
// TLS-соединение и печатает задержку первого обмена и ответы A-записей.
// Коды возврата совпадают с контрактом dot_alive в z2k-dns-check.sh:
//
//	0 — TLS проверен, контрольный обмен успешен;
//	1 — таймаут, обрыв соединения или отказ проверки сертификата;
//	2 — в системе нет корневых сертификатов для проверки цепочки.
func dnsdotCmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("dnsdot", flag.ExitOnError)
	server := fs.String("server", "", "имя или IP DoT-сервера для проверки сертификата")
	addr := fs.String("addr", "", "адрес подключения (по умолчанию -server)")
	timeout := fs.Duration("timeout", 5*time.Second, "потолок ожидания")
	cafile := fs.String("cafile", "", "дополнительный PEM-файл корневых сертификатов")
	_ = fs.Parse(rest)

	if *server == "" {
		fatal("нужен -server")
	}
	var items []dotItem
	for _, raw := range fs.Args() {
		p, d := "target", raw
		if idx := strings.IndexByte(raw, ':'); idx > 0 {
			p, d = raw[:idx], raw[idx+1:]
		}
		if d != "" {
			items = append(items, dotItem{purpose: p, domain: d})
		}
	}
	if len(items) == 0 {
		items = []dotItem{{purpose: "control", domain: "example.com"}}
	}

	ms, res, err := dnsDoTBatch(ctx, *server, *addr, *cafile, *timeout, items)
	if err != nil {
		if errors.Is(err, errNoVerifyRoots) {
			fmt.Fprintf(os.Stderr, "нечем проверить TLS для %s: %v\n", *server, err)
			os.Exit(2)
		}
		fmt.Fprintf(os.Stderr, "ошибка DoT %s: %v\n", *server, err)
		os.Exit(1)
	}
	if ms > 0 {
		fmt.Printf("ms\t%d\n", ms)
	}
	for _, r := range res {
		fmt.Printf("obs\t%s\t%s\t%s\t%s\n", r.purpose, r.domain, r.outcome, strings.Join(r.addrs, ","))
	}
}

func hasCertFilesInDir(dir string) bool {
	if dir == "" {
		return false
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, ".pem") || strings.HasSuffix(name, ".crt") || strings.HasSuffix(name, ".0") {
			if info, ierr := e.Info(); ierr == nil && info.Size() > 0 {
				return true
			}
		}
	}
	return false
}

func appendCertsFromDir(pool *x509.CertPool, dir string) bool {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	added := false
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".pem") && !strings.HasSuffix(name, ".crt") && !strings.HasSuffix(name, ".0") {
			continue
		}
		if b, rerr := os.ReadFile(filepath.Join(dir, name)); rerr == nil && pool.AppendCertsFromPEM(b) {
			added = true
		}
	}
	return added
}

func loadDoTRoots(extraCA string) (pool *x509.CertPool, onlyFallback bool, err error) {
	if extraCA != "" {
		p := x509.NewCertPool()
		b, rerr := os.ReadFile(extraCA)
		if rerr != nil {
			return nil, false, fmt.Errorf("%w: %v", errNoVerifyRoots, rerr)
		}
		if !p.AppendCertsFromPEM(b) {
			return nil, false, errNoVerifyRoots
		}
		return p, false, nil
	}

	hasFullBundle := false
	sysPool, sysErr := x509.SystemCertPool()
	if sysErr == nil && sysPool != nil {
		pool = sysPool
		if runtime.GOOS != "linux" {
			hasFullBundle = true
		} else {
			// На голом NDMS без корней SystemCertPool возвращает пустой пул без
			// ошибки; проверяем и бандл-файлы, и каталоги корней прошивки (см. z2k-warp.sh).
			fileCands := []string{
				os.Getenv("SSL_CERT_FILE"),
				"/etc/ssl/certs/ca-certificates.crt",
				"/etc/pki/tls/certs/ca-bundle.crt",
				"/etc/ssl/ca-bundle.pem",
				"/etc/pki/tls/cacert.pem",
				"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
				"/etc/ssl/cert.pem",
			}
			for _, std := range fileCands {
				if std == "" {
					continue
				}
				if st, e := os.Stat(std); e == nil && !st.IsDir() && st.Size() > 0 {
					hasFullBundle = true
					break
				}
			}
			if !hasFullBundle {
				for _, dir := range []string{os.Getenv("SSL_CERT_DIR"), "/etc/ssl/certs", "/etc/pki/tls/certs"} {
					if hasCertFilesInDir(dir) {
						hasFullBundle = true
						break
					}
				}
			}
		}
	} else {
		pool = x509.NewCertPool()
	}

	// В Entware пакеты ca-bundle / ca-certificates кладут корни в /opt/etc/ssl,
	// о котором стандартная библиотека Go не знает.
	for _, cand := range []string{
		"/opt/etc/ssl/certs/ca-certificates.crt",
		"/opt/etc/ssl/cert.pem",
		"/etc/ssl/certs/ca-certificates.crt",
	} {
		if b, rerr := os.ReadFile(cand); rerr == nil && pool.AppendCertsFromPEM(b) {
			hasFullBundle = true
		}
	}
	if appendCertsFromDir(pool, "/opt/etc/ssl/certs") {
		hasFullBundle = true
	}

	hasZ2K := false
	z2kDir := os.Getenv("ZAPRET2_DIR")
	if z2kDir == "" {
		z2kDir = "/opt/zapret2"
	}
	if b, rerr := os.ReadFile(filepath.Join(z2kDir, "etc", "z2k-roots.pem")); rerr == nil && pool.AppendCertsFromPEM(b) {
		hasZ2K = true
	}

	if !hasFullBundle && !hasZ2K {
		return nil, false, errNoVerifyRoots
	}
	return pool, !hasFullBundle && hasZ2K, nil
}

func dialDoT(ctx context.Context, dialAddr, serverName string, pool *x509.CertPool, onlyFallback bool, timeout time.Duration) (*tls.Conn, error) {
	deadline := time.Now().Add(timeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	dialer := &net.Dialer{Deadline: deadline}
	rawConn, err := dialer.DialContext(ctx, "tcp", dialAddr)
	if err != nil {
		return nil, err
	}
	if err := rawConn.SetDeadline(deadline); err != nil {
		_ = rawConn.Close()
		return nil, err
	}
	tlsConn := tls.Client(rawConn, &tls.Config{
		RootCAs:    pool,
		ServerName: serverName,
		MinVersion: tls.VersionTLS12,
	})
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = rawConn.Close()
		var uaErr x509.UnknownAuthorityError
		if onlyFallback && errors.As(err, &uaErr) {
			// Если присланный сертификат самоподписан (Issuer == Subject), это не
			// нехватка корневого центра в z2k-roots.pem, а невалидный/подменённый узел.
			if uaErr.Cert != nil && !bytes.Equal(uaErr.Cert.RawIssuer, uaErr.Cert.RawSubject) {
				return nil, errNoVerifyRoots
			}
		}
		return nil, err
	}
	return tlsConn, nil
}

func dnsDoTBatch(ctx context.Context, server, addr, cafile string, timeout time.Duration, items []dotItem) (int64, []dotResult, error) {
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	pool, onlyFallback, err := loadDoTRoots(cafile)
	if err != nil {
		return 0, nil, err
	}
	serverName := strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(server), "["), "]")
	if idx := strings.IndexByte(serverName, '%'); idx > 0 {
		serverName = serverName[:idx]
	}
	if h, _, serr := net.SplitHostPort(serverName); serr == nil && strings.Count(serverName, ":") == 1 {
		serverName = h
	}
	target := addr
	if strings.TrimSpace(target) == "" {
		target = server
	}
	dialAddr := normalizeHostPort(target, "853")

	probeIdx := 0
	for i, it := range items {
		if it.purpose == "control" {
			probeIdx = i
			break
		}
	}

	baseID := uint16(rand.Intn(0x7fff)) + 1
	queries := make([][]byte, len(items))
	ids := make([]uint16, len(items))
	for i, it := range items {
		id := baseID + uint16(i)
		q, qerr := dnsQuery(id, it.domain)
		if qerr != nil {
			return 0, nil, qerr
		}
		ids[i] = id
		queries[i] = q
	}

	start := time.Now()
	tlsConn, err := dialDoT(ctx, dialAddr, serverName, pool, onlyFallback, timeout)
	if err != nil {
		return 0, nil, err
	}
	defer tlsConn.Close()

	if err := writeDoTFrame(tlsConn, queries[probeIdx]); err != nil {
		return 0, nil, err
	}
	firstPkt, err := readDoTFrame(tlsConn)
	if err != nil {
		return 0, nil, err
	}
	ms := time.Since(start).Milliseconds()
	if ms < 1 {
		ms = 1
	}

	res := make([]dotResult, len(items))
	done := make([]bool, len(items))
	for i, it := range items {
		res[i] = dotResult{purpose: it.purpose, domain: it.domain, outcome: "error"}
	}

	addrs0, err := parseDNSAnswerA(firstPkt, ids[probeIdx])
	if err != nil {
		return 0, nil, err
	}
	res[probeIdx] = makeDoTResult(items[probeIdx], addrs0)
	if res[probeIdx].outcome != "addresses" {
		// Как и в doh_wire_ms / udp_ms, задержка публикуется только при непустом A на контроле.
		ms = 0
	}
	done[probeIdx] = true

	if len(items) == 1 {
		return ms, res, nil
	}

	// Отправляем оставшиеся вопросы конвейером в то же открытое TLS-соединение
	// (RFC 7858 §3.3). Ответы сопоставляются по идентификатору заголовка DNS.
	idToIdx := make(map[uint16]int, len(items)-1)
	var batch []byte
	for i := range items {
		if i == probeIdx {
			continue
		}
		idToIdx[ids[i]] = i
		var hdr [2]byte
		binary.BigEndian.PutUint16(hdr[:], uint16(len(queries[i])))
		batch = append(batch, hdr[:]...)
		batch = append(batch, queries[i]...)
	}

	pipeOK := true
	if _, err := tlsConn.Write(batch); err != nil {
		pipeOK = false
	}
	for rem := len(idToIdx); pipeOK && rem > 0; rem-- {
		pkt, rerr := readDoTFrame(tlsConn)
		if rerr != nil || len(pkt) < 12 {
			pipeOK = false
			break
		}
		respID := binary.BigEndian.Uint16(pkt[0:2])
		idx, ok := idToIdx[respID]
		if !ok || done[idx] {
			pipeOK = false
			break
		}
		if addrs, perr := parseDNSAnswerA(pkt, respID); perr == nil {
			res[idx] = makeDoTResult(items[idx], addrs)
		}
		done[idx] = true
	}

	// Резервный допрос для редких серверов, закрывающих соединение после одного ответа
	// (строго в пределах общего дедлайна ctx, без умножения таймаута на число доменов).
	if !pipeOK && ctx.Err() == nil {
		for i, it := range items {
			if done[i] {
				continue
			}
			if ctx.Err() != nil {
				break
			}
			c2, derr := dialDoT(ctx, dialAddr, serverName, pool, onlyFallback, timeout)
			if derr != nil {
				break
			}
			if werr := writeDoTFrame(c2, queries[i]); werr == nil {
				if pkt, rerr := readDoTFrame(c2); rerr == nil {
					if addrs, perr := parseDNSAnswerA(pkt, ids[i]); perr == nil {
						res[i] = makeDoTResult(it, addrs)
					}
				}
			}
			_ = c2.Close()
			done[i] = true
		}
	}

	return ms, res, nil
}

func makeDoTResult(it dotItem, addrs []string) dotResult {
	if len(addrs) > 0 {
		return dotResult{purpose: it.purpose, domain: it.domain, outcome: "addresses", addrs: addrs}
	}
	return dotResult{purpose: it.purpose, domain: it.domain, outcome: "no_a"}
}

func writeDoTFrame(w io.Writer, pkt []byte) error {
	buf := make([]byte, 2+len(pkt))
	binary.BigEndian.PutUint16(buf[0:2], uint16(len(pkt)))
	copy(buf[2:], pkt)
	_, err := w.Write(buf)
	return err
}

func readDoTFrame(r io.Reader) ([]byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	length := int(binary.BigEndian.Uint16(hdr[:]))
	if length < 12 || length > 65535 {
		return nil, fmt.Errorf("некорректная длина DoT-фрейма: %d", length)
	}
	pkt := make([]byte, length)
	if _, err := io.ReadFull(r, pkt); err != nil {
		return nil, err
	}
	return pkt, nil
}

func skipDNSName(pkt []byte, p int) (int, bool) {
	for p < len(pkt) {
		l := int(pkt[p])
		if l >= 192 {
			if p+1 >= len(pkt) {
				return 0, false
			}
			return p + 2, true
		}
		if l == 0 {
			return p + 1, true
		}
		if l > 63 || p+1+l > len(pkt) {
			return 0, false
		}
		p += 1 + l
	}
	return 0, false
}

// parseDNSAnswerA разбирает полный DNS-ответ (согласованно с dns_file_a в
// z2k-dns-check.sh): проверяет ID, флаги QR/TC, секции и извлекает уникальные A.
// Корректный ответ с ненулевым RCODE (например, NXDOMAIN) возвращает пустой срез без ошибки.
func parseDNSAnswerA(pkt []byte, wantID uint16) ([]string, error) {
	if len(pkt) < 12 {
		return nil, fmt.Errorf("ответ короче заголовка: %d", len(pkt))
	}
	if binary.BigEndian.Uint16(pkt[0:2]) != wantID {
		return nil, fmt.Errorf("чужой идентификатор DNS")
	}
	if pkt[2]&0x80 == 0 || pkt[2]&0x02 != 0 {
		return nil, fmt.Errorf("некорректные флаги заголовка: %#x", pkt[2])
	}
	qd := int(binary.BigEndian.Uint16(pkt[4:6]))
	an := int(binary.BigEndian.Uint16(pkt[6:8]))
	if qd != 1 {
		return nil, fmt.Errorf("неожиданный QDCOUNT=%d", qd)
	}
	p, ok := skipDNSName(pkt, 12)
	if !ok || p+4 > len(pkt) {
		return nil, fmt.Errorf("повреждена секция вопроса")
	}
	p += 4

	seen := make(map[string]struct{})
	var out []string
	for k := 0; k < an; k++ {
		p, ok = skipDNSName(pkt, p)
		if !ok || p+10 > len(pkt) {
			return nil, fmt.Errorf("повреждён заголовок RR")
		}
		rrType := binary.BigEndian.Uint16(pkt[p : p+2])
		rrClass := binary.BigEndian.Uint16(pkt[p+2 : p+4])
		rdLen := int(binary.BigEndian.Uint16(pkt[p+8 : p+10]))
		p += 10
		if p+rdLen > len(pkt) {
			return nil, fmt.Errorf("обрезаны данные RR")
		}
		if rrType == 1 && rrClass == 1 && rdLen == 4 {
			ip := net.IPv4(pkt[p], pkt[p+1], pkt[p+2], pkt[p+3]).String()
			if _, dup := seen[ip]; !dup {
				seen[ip] = struct{}{}
				out = append(out, ip)
			}
		}
		p += rdLen
	}
	if pkt[3]&0x0f != 0 {
		return nil, nil
	}
	sort.Strings(out)
	return out, nil
}

// dnsQuery — запрос A-записи по RFC 1035 §4.1.
func dnsQuery(id uint16, name string) ([]byte, error) {
	name = strings.TrimSuffix(strings.TrimSpace(name), ".")
	if name == "" {
		return nil, fmt.Errorf("пустое имя")
	}
	out := make([]byte, 12, 12+len(name)+6)
	binary.BigEndian.PutUint16(out[0:2], id)
	out[2] = 0x01 // RD — рекурсия
	binary.BigEndian.PutUint16(out[4:6], 1)
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 {
			return nil, fmt.Errorf("негодная метка в имени: %q", label)
		}
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	out = append(out, 0x00)
	out = append(out, 0x00, 0x01) // QTYPE=A
	out = append(out, 0x00, 0x01) // QCLASS=IN
	return out, nil
}
