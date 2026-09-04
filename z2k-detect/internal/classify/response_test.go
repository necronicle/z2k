package classify

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"sync"
	"testing"
	"time"
)

// СТЕНД ОТВЕТНОГО НАПРАВЛЕНИЯ.
//
// Изображает коробку, которая пропускает запрос и убивает ОТВЕТ: ClientHello
// доходит, ServerHello уходит обратно, а на сертификате соединение рвётся.
// Это единственный способ проверить, что вердикт «проходит как есть» больше не
// выдаётся там, где сайт на самом деле не открывается.
//
// Рвём именно ПОСЛЕ ServerHello, а не до: обрыв до него — это блок запроса, его
// ловит основное дерево, и спутать эти два класса нельзя.

// killAfter рвёт соединение, когда сервер написал больше limit байт.
type killAfter struct {
	net.Conn
	mu      sync.Mutex
	written int
	limit   int // 0 — не рвать
}

func (k *killAfter) Write(b []byte) (int, error) {
	k.mu.Lock()
	limit := k.limit
	k.written += len(b)
	total := k.written
	k.mu.Unlock()
	n, err := k.Conn.Write(b)
	if limit > 0 && total > limit {
		_ = k.Conn.Close()
	}
	return n, err
}

func (k *killAfter) arm(limit int) {
	k.mu.Lock()
	k.limit = limit
	k.mu.Unlock()
}

func selfSigned(t *testing.T) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "stand"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// startStand поднимает сервер TLS 1.2, который рвёт ответ для имени blocked.
// maxVer позволяет изобразить сервер, не умеющий 1.2.
func startStand(t *testing.T, blocked string, maxVer uint16) string {
	t.Helper()
	cert := selfSigned(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	go func() {
		for {
			raw, err := ln.Accept()
			if err != nil {
				return
			}
			go func(raw net.Conn) {
				defer raw.Close()
				k := &killAfter{Conn: raw}
				cfg := &tls.Config{
					Certificates: []tls.Certificate{cert},
					MinVersion:   tls.VersionTLS12,
					MaxVersion:   maxVer,
					GetConfigForClient: func(chi *tls.ClientHelloInfo) (*tls.Config, error) {
						if blocked != "" && chi.ServerName == blocked {
							// ServerHello в TLS 1.2 около сотни байт; рвём
							// после него, на сертификате.
							k.arm(150)
						}
						return nil, nil
					},
				}
				c := tls.Server(k, cfg)
				_ = c.SetDeadline(time.Now().Add(3 * time.Second))
				_ = c.Handshake()
				_ = c.Close()
			}(raw)
		}
	}()
	return ln.Addr().String()
}

func respOpts() Options {
	return Options{Repeats: 3, Timeout: 3 * time.Second, AllowLoopback: true}
}

// Главный случай: запрос проходит, ответ режут. Раньше такой домен получал
// вердикт «проходит как есть», человек шёл искать поломку у себя.
func TestResponseBlockDetected(t *testing.T) {
	addr := startStand(t, "blocked.example", tls.VersionTLS12)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	rr := ProbeResponse(ctx, addr, "blocked.example", respOpts())
	if rr.Verdict != RespBlocked {
		t.Fatalf("вердикт %q (%s), ожидался %q; цель %d, контроль %d",
			rr.Verdict, rr.Reason, RespBlocked, rr.Target, rr.Control)
	}
}

// Обратный случай: никого не режут — вердикт обязан быть «чисто», иначе
// инструмент начнёт пугать людей на ровном месте.
func TestResponseClearWhenNobodyCuts(t *testing.T) {
	addr := startStand(t, "", tls.VersionTLS12)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	rr := ProbeResponse(ctx, addr, "anything.example", respOpts())
	if rr.Verdict != RespClear {
		t.Fatalf("вердикт %q (%s), ожидался %q", rr.Verdict, rr.Reason, RespClear)
	}
}

// Сервер не умеет TLS 1.2 — значит сертификат в открытую он не шлёт никогда, и
// класса блокировки не существует. Это «не измерено», а не «чисто»: выдать
// одно за другое значит соврать.
func TestResponseNotApplicableOnTLS13OnlyServer(t *testing.T) {
	cert := selfSigned(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			raw, err := ln.Accept()
			if err != nil {
				return
			}
			go func(raw net.Conn) {
				defer raw.Close()
				c := tls.Server(raw, &tls.Config{
					Certificates: []tls.Certificate{cert},
					MinVersion:   tls.VersionTLS13, // 1.2 не поддерживаем
				})
				_ = c.SetDeadline(time.Now().Add(3 * time.Second))
				_ = c.Handshake()
			}(raw)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rr := ProbeResponse(ctx, ln.Addr().String(), "anything.example", respOpts())
	if rr.Verdict != RespNotApplicable {
		t.Fatalf("вердикт %q (%s), ожидался %q", rr.Verdict, rr.Reason, RespNotApplicable)
	}
}

// И самое важное — сквозной путь: Run обязан поменять вердикт с «чисто» на
// «режут ответ». Стенд пропускает наш ClientHello целиком, поэтому основное
// дерево дошло бы до VerdictClear.
func TestRunTurnsClearIntoResponseBlock(t *testing.T) {
	addr := startStand(t, "blocked.example", tls.VersionTLS12)
	tr, err := TLSTrigger("blocked.example")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	res := Run(ctx, addr, tr, respOpts())
	if res.Verdict != VerdictResponse {
		t.Fatalf("вердикт %q (%s), ожидался %q", res.Verdict, res.Reason, VerdictResponse)
	}
	if res.Response == nil || res.Response.Control == 0 {
		t.Errorf("контроль не отработал: %+v", res.Response)
	}
}
