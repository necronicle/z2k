package main

import (
	"bufio"
	"flag"
	"net"
	"testing"
)

// withDirectStub подменяет прямой путь и считает обращения к нему.
func withDirectStub(t *testing.T, up net.Conn, br *bufio.Reader) *int {
	t.Helper()
	calls := 0
	prev := dialDirectFn
	dialDirectFn = func(string, []byte) (net.Conn, *bufio.Reader) {
		calls++
		return up, br
	}
	t.Cleanup(func() { dialDirectFn = prev })
	return &calls
}

// Внешнее имя ECH узлы пула обслужить не могут (замер 04.11: 27 из 27 — EOF после
// CONNECT 200), поэтому обращаться к ним незачем: каждая попытка стоит клиенту
// до --first-byte-timeout.
func TestConnectTarget_ECHPublicNameGoesDirectWithoutTouchingThePool(t *testing.T) {
	for _, sni := range []string{"cloudflare-ech.com", "Cloudflare-ECH.com", "cloudflare-ech.com."} {
		c, br := newStubTunnel()
		calls := withDirectStub(t, c, br)
		withTunnelStubs(t,
			func(ip, target string) (net.Conn, *bufio.Reader, bool, bool) {
				t.Errorf("%s: пул не должен участвовать, был CONNECT %s через %s", sni, target, ip)
				return nil, nil, false, false
			},
			func(string, net.Conn, *bufio.Reader, []byte) bool { return false })

		p := &pool{live: []string{"203.0.113.1"}}
		up, _ := connectTarget(p, sni, []byte("hello"))
		if up == nil {
			t.Errorf("%s: прямое соединение должно быть возвращено", sni)
		}
		if *calls != 1 {
			t.Errorf("%s: прямой путь вызван %d раз, ожидался 1", sni, *calls)
		}
	}
}

// Настоящее имя по-прежнему идёт через пул: прямой путь для него только запасной.
func TestConnectTarget_OrdinaryNameTriesThePoolFirst(t *testing.T) {
	calls := withDirectStub(t, nil, nil)
	withTunnelStubs(t,
		func(string, string) (net.Conn, *bufio.Reader, bool, bool) {
			c, br := newStubTunnel()
			return c, br, true, true
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	p := &pool{live: []string{"203.0.113.1"}}
	if up, _ := connectTarget(p, "rutracker.org", []byte("hello")); up == nil {
		t.Fatal("рабочий узел пула должен быть использован")
	}
	if *calls != 0 {
		t.Fatalf("при живом пуле прямой путь не нужен, вызван %d раз", *calls)
	}
}

// Прежнее поведение запасного пути: пул не справился — идём напрямую.
func TestConnectTarget_OrdinaryNameFallsBackWhenThePoolFails(t *testing.T) {
	c, br := newStubTunnel()
	calls := withDirectStub(t, c, br)

	old := *pickWaitTO
	*pickWaitTO = 0
	t.Cleanup(func() { *pickWaitTO = old })

	if up, _ := connectTarget(&pool{}, "rutracker.org", []byte("hello")); up == nil {
		t.Fatal("при отказе пула должен сработать прямой путь")
	}
	if *calls != 1 {
		t.Fatalf("прямой путь вызван %d раз, ожидался 1", *calls)
	}
}

// Выключатель прямого пути обязан действовать и на внешнее имя ECH.
func TestConnectTarget_DirectFallbackOffDisablesTheECHShortcut(t *testing.T) {
	calls := withDirectStub(t, nil, nil)
	oldOn, oldWait := *directFallback, *pickWaitTO
	*directFallback, *pickWaitTO = false, 0
	t.Cleanup(func() { *directFallback, *pickWaitTO = oldOn, oldWait })

	if up, _ := connectTarget(&pool{}, "cloudflare-ech.com", []byte("hello")); up != nil {
		t.Fatal("при выключенном прямом пути соединения быть не должно")
	}
	if *calls != 0 {
		t.Fatalf("прямой путь выключен, но вызван %d раз", *calls)
	}
}

// Проверяем именно значение по умолчанию: init-скрипт флаг не передаёт, и без имени
// в этом списке dialDirect откажет, какой бы путь ни выбрал connectTarget.
func TestDirectHosts_DefaultAllowsOnlyTheExactECHPublicName(t *testing.T) {
	old := *directHosts
	*directHosts = flag.Lookup("direct-fallback-hosts").DefValue
	t.Cleanup(func() { *directHosts = old })

	if !directHostAllowed("cloudflare-ech.com") {
		t.Error("cloudflare-ech.com должен быть разрешён по умолчанию")
	}
	for _, h := range []string{"evilcloudflare-ech.com", "cloudflare-ech.com.evil.tld", "cloudflare.com"} {
		if directHostAllowed(h) {
			t.Errorf("%q разрешать нельзя", h)
		}
	}
}
