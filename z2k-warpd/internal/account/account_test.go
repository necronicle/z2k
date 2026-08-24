package account

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const regBody = `{"id":"dev1","token":"tok1","warp_enabled":false,
 "config":{"client_id":"Mv0s","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:8::1"}},
 "peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
 "endpoint":{"v4":"8.6.112.0:0","host":"engage.cloudflareclient.com:2408","ports":[854,859]}}]}}`

// badRegBody — тот же ответ, но с эндпоинтом из негодного диапазона.
var badRegBody = strings.Replace(regBody, `"v4":"8.6.112.0:0"`, `"v4":"162.159.192.9:0"`, 1)

func srv(t *testing.T, patched *bool) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "POST" && r.URL.Path == "/v0a2158/reg":
			if r.Header.Get("CF-Client-Version") == "" {
				t.Error("no CF-Client-Version")
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["key"] == "" {
				t.Errorf("bad register body: %v %v", body, err)
			}
			if body["key_type"] != "curve25519" || body["tunnel_type"] != "wireguard" {
				t.Errorf("register must declare wireguard key: %v", body)
			}
			w.Write([]byte(regBody))
		case r.Method == "PATCH" && r.URL.Path == "/v0a2158/reg/dev1":
			if r.Header.Get("Authorization") != "Bearer tok1" {
				t.Error("no bearer")
			}
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			if body["warp_enabled"] == true {
				*patched = true
				w.Write([]byte(`{"warp_enabled":true}`))
				return
			}
			if body["key_type"] == "secp256r1" && body["tunnel_type"] == "masque" {
				if s, _ := body["key"].(string); len(s) < 80 {
					t.Errorf("masque key too short: %q", s)
				}
				w.Write([]byte(`{"id":"dev1","config":{"client_id":"Mv0s","interface":{"addresses":{"v4":"172.16.0.2"}},
				 "peers":[{"public_key":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpeer","endpoint":{"v4":"162.159.198.1:443","ports":[]}}]}}`))
				return
			}
			if body["key_type"] == "curve25519" && body["tunnel_type"] == "wireguard" {
				w.Write([]byte(regBody))
				return
			}
			t.Errorf("unexpected PATCH body %v", body)
			w.WriteHeader(400)
		case r.Method == "GET" && r.URL.Path == "/v0a2158/reg/dev1":
			w.Write([]byte(regBody))
		case r.Method == "GET" && r.URL.Path == "/v0a2158/reg/gone":
			w.WriteHeader(404)
		default:
			w.WriteHeader(500)
		}
	}))
}

func TestRegisterFillsDeviceAndEnablesWarp(t *testing.T) {
	var patched bool
	s := srv(t, &patched)
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	d, err := c.Register(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !patched {
		t.Fatal("warp_enabled not patched")
	}
	if d.ID != "dev1" || d.Token != "tok1" || d.ClientID != "Mv0s" {
		t.Fatalf("%+v", d)
	}
	if d.AddrV4 != "172.16.0.2" || d.Endpoint.V4 != "8.6.112.0" {
		t.Fatalf("%+v", d)
	}
	if d.PeerKey != "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=" {
		t.Fatalf("peer key %q", d.PeerKey)
	}
	if len(d.Endpoint.Ports) != 2 || d.Endpoint.Ports[0] != 854 {
		t.Fatalf("ports %v", d.Endpoint.Ports)
	}
	if d.PrivateKey == "" {
		t.Fatal("no private key generated")
	}
	r, err := d.Reserved()
	if err != nil || r != [3]byte{0x32, 0xfd, 0x2c} {
		t.Fatalf("reserved %v %v", r, err)
	}
}

func TestRefreshUpdatesEndpointKeepsIdentity(t *testing.T) {
	s := srv(t, new(bool))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	d := &Device{ID: "dev1", Token: "tok1", PrivateKey: "keep"}
	if err := c.Refresh(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if d.PrivateKey != "keep" || d.ID != "dev1" || d.Endpoint.V4 != "8.6.112.0" || d.ClientID != "Mv0s" {
		t.Fatalf("%+v", d)
	}
}

func TestRefreshKeepsPrimaryEndpointCollectsAlt(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"id":"dev1","config":{"client_id":"Mv0s","interface":{"addresses":{"v4":"172.16.0.2"}},
		 "peers":[{"public_key":"pk","endpoint":{"v4":"162.159.192.10:0","ports":[500,1701]}}]}}`))
	}))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	d := &Device{ID: "dev1", Token: "t", Tunnel: TunnelWG, Endpoint: Endpoint{V4: "8.6.112.0", Ports: []int{854}}}
	if err := c.Refresh(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if d.Endpoint.V4 != "8.6.112.0" || len(d.Endpoint.Ports) != 1 {
		t.Fatalf("primary overwritten: %+v", d.Endpoint)
	}
	if len(d.Endpoint.Alt) != 1 || d.Endpoint.Alt[0].Host != "162.159.192.10" || len(d.Endpoint.Alt[0].Ports) != 2 {
		t.Fatalf("alt not collected: %+v", d.Endpoint.Alt)
	}
	c.Refresh(context.Background(), d) // повтор — без дублей
	if len(d.Endpoint.Alt) != 1 {
		t.Fatalf("alt duplicated: %+v", d.Endpoint.Alt)
	}
}

func TestRefreshRevoked(t *testing.T) {
	s := srv(t, new(bool))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	d := &Device{ID: "gone", Token: "x"}
	if err := c.Refresh(context.Background(), d); err != ErrRevoked {
		t.Fatalf("want ErrRevoked, got %v", err)
	}
}

func TestSaveLoadRoundTripMode600(t *testing.T) {
	p := filepath.Join(t.TempDir(), "device.json")
	d := &Device{ID: "a", Token: "b", PrivateKey: "k", ClientID: "Mv0s", Iface: "z2ktun0"}
	if err := d.Save(p); err != nil {
		t.Fatal(err)
	}
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0600 {
		t.Fatalf("mode %o", st.Mode().Perm())
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("tmp left behind")
	}
	got, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if got.Iface != "z2ktun0" || got.ClientID != "Mv0s" {
		t.Fatalf("%+v", got)
	}
	var raw map[string]any
	b, _ := os.ReadFile(p)
	json.Unmarshal(b, &raw)
	if _, ok := raw["h2"]; ok {
		t.Fatal("empty h2 must be omitted")
	}
	if _, ok := raw["last_good"]; ok {
		t.Fatal("empty last_good must be omitted")
	}
}

func TestSwitchTunnelMasqueThenBack(t *testing.T) {
	s := srv(t, new(bool))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	d, err := c.Register(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if d.Tunnel != TunnelWG {
		t.Fatalf("tunnel %q", d.Tunnel)
	}
	if err := c.SwitchTunnel(context.Background(), d, TunnelMasque); err != nil {
		t.Fatal(err)
	}
	if d.Tunnel != TunnelMasque || d.H2 == nil || d.H2.PrivateKey == "" || d.H2.PeerKey != "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpeer" {
		t.Fatalf("%+v %+v", d, d.H2)
	}
	if d.Endpoint.V4 != "8.6.112.0" || len(d.Endpoint.Alt) != 0 {
		t.Fatalf("masque switch must not touch WG endpoint: %+v", d.Endpoint)
	}
	if _, err := ECPrivateKey(d.H2.PrivateKey); err != nil {
		t.Fatal(err)
	}
	h2key := d.H2.PrivateKey
	if err := c.SwitchTunnel(context.Background(), d, TunnelWG); err != nil {
		t.Fatal(err)
	}
	if d.Tunnel != TunnelWG || d.Endpoint.V4 != "8.6.112.0" || d.H2.PrivateKey != h2key {
		t.Fatalf("%+v", d)
	}
}

func TestEnsureExistingDeviceIsNotReRegistered(t *testing.T) {
	posts := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "POST":
			posts++
			w.Write([]byte(regBody))
		case r.Method == "PATCH":
			w.Write([]byte(`{"warp_enabled":true}`))
		case r.Method == "GET" && r.URL.Path == "/v0a2158/reg/dev1":
			w.Write([]byte(regBody))
		case r.Method == "GET" && r.URL.Path == "/v0a2158/reg/gone":
			w.WriteHeader(404)
		case r.Method == "GET" && r.URL.Path == "/v0a2158/reg/flaky":
			w.WriteHeader(503)
		default:
			w.WriteHeader(500)
		}
	}))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	p := filepath.Join(t.TempDir(), "device.json")

	// нет файла → регистрация
	d, created, err := c.Ensure(context.Background(), p)
	if err != nil || !created || d.ID != "dev1" || posts != 1 {
		t.Fatalf("fresh: created=%v err=%v posts=%d", created, err, posts)
	}
	// файл есть, GET 200 → без POST
	d, created, err = c.Ensure(context.Background(), p)
	if err != nil || created || posts != 1 {
		t.Fatalf("existing: created=%v err=%v posts=%d", created, err, posts)
	}
	// файл есть, GET 503 → ошибка, без POST (не сжигать устройство на сетевой ошибке)
	d.ID = "flaky"
	d.Save(p)
	if _, created, err = c.Ensure(context.Background(), p); err == nil || created || posts != 1 {
		t.Fatalf("flaky: created=%v err=%v posts=%d", created, err, posts)
	}
	// файл есть, GET 404 (отозвано) → новая регистрация
	d.ID = "gone"
	d.Save(p)
	if _, created, err = c.Ensure(context.Background(), p); err != nil || !created || posts != 2 {
		t.Fatalf("revoked: created=%v err=%v posts=%d", created, err, posts)
	}
}

// Эндпоинт из 162.159.192.0/24 — не «редкий случай», а негодная регистрация.
//
// Замер, из-за которого версия API и пинится: v0a4471 отдаёт этот диапазон с
// ЧЕТЫРЬМЯ портами, и РФ-провайдеры его режут — WireGuard не получает
// рукопожатия ни на одном порту. Рабочая регистрация даёт 8.x анкастом с
// полусотней портов. Поле 2026-08-24: у человека tx=314 КБ, rx=248 байт,
// компьютер завёрнут в чёрную дыру, а починить нечем — «Удалить WARP»
// намеренно сохраняет ключ, и переустановка возвращает ту же мёртвую запись.
func TestBadEndpointRangeIsRejected(t *testing.T) {
	for _, tc := range []struct {
		host string
		bad  bool
	}{
		{"162.159.192.9", true},
		{"162.159.192.1", true},
		{"162.159.193.9", false}, // соседняя /24 под запрет не попадает
		{"8.6.112.0", false},
		{"188.114.97.1", false},
		{"", false},
	} {
		if got := badEndpoint(tc.host); got != tc.bad {
			t.Errorf("badEndpoint(%q) = %v, want %v", tc.host, got, tc.bad)
		}
	}
}

// Сохранённая запись с негодным адресом чинится САМА, один раз: перерегистрация
// на старте. Именно на старте, а не по факту неудачи туннеля — «туннель не
// поднялся» имеет десяток причин (провайдер, DPI, поезд), и перерегистрация по
// такому признаку жгла бы регистрации Cloudflare в цикле у того, у кого просто
// плохая сеть. Признак негодного адреса детерминированный и самоограниченный:
// новая запись плохого диапазона уже не содержит, значит второй раз не сработает.
func TestEnsureReRegistersOnBadEndpoint(t *testing.T) {
	posts := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "POST":
			posts++
			w.Write([]byte(regBody))
		case r.Method == "PATCH":
			w.Write([]byte(`{"warp_enabled":true}`))
		case r.Method == "GET":
			w.Write([]byte(regBody))
		default:
			w.WriteHeader(500)
		}
	}))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	p := filepath.Join(t.TempDir(), "device.json")

	bad := &Device{ID: "dev1", Token: "t", PrivateKey: "k", Tunnel: TunnelWG,
		Endpoint: Endpoint{V4: "162.159.192.9", Ports: []int{2408, 500, 1701, 4500}}}
	if err := bad.Save(p); err != nil {
		t.Fatal(err)
	}
	d, created, err := c.Ensure(context.Background(), p)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if !created || posts != 1 {
		t.Fatalf("негодный адрес обязан вызвать перерегистрацию: created=%v posts=%d", created, posts)
	}
	if badEndpoint(d.Endpoint.V4) {
		t.Fatalf("после перерегистрации адрес снова негодный: %s", d.Endpoint.V4)
	}
	// Второй прогон уже НЕ перерегистрирует: запись здоровая.
	if _, created, err = c.Ensure(context.Background(), p); err != nil || created || posts != 1 {
		t.Fatalf("повторный прогон: created=%v err=%v posts=%d", created, err, posts)
	}
}

// Неудачная перерегистрация НЕ должна оставить человека без устройства: пока
// новая запись не получена, старая остаётся на диске. Негодная лучше, чем
// никакой — с ней хотя бы виден диагноз.
func TestBadEndpointKeptWhenReRegistrationFails(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			w.WriteHeader(503)
			return
		}
		w.Write([]byte(regBody))
	}))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	p := filepath.Join(t.TempDir(), "device.json")
	bad := &Device{ID: "dev1", Token: "t", PrivateKey: "k", Tunnel: TunnelWG,
		Endpoint: Endpoint{V4: "162.159.192.9", Ports: []int{2408}}}
	bad.Save(p)

	if _, _, err := c.Ensure(context.Background(), p); err == nil {
		t.Fatal("перерегистрация провалилась — Ensure обязан вернуть ошибку")
	}
	back, err := Load(p)
	if err != nil || back.ID != "dev1" || back.Endpoint.V4 != "162.159.192.9" {
		t.Fatalf("старая запись должна была уцелеть: %+v err=%v", back, err)
	}
}

// Перерегистрация — РОВНО ОДНА на запись.
//
// Если API у человека отдаёт плохой диапазон и в ответ на новую регистрацию
// тоже, наивная проверка «адрес плохой → регистрируйся» сработает при КАЖДОМ
// старте демона и сожжёт лимит устройств Cloudflare. Отметка в записи делает
// попытку одноразовой: сеть починится — поможет кнопка в панели, а не цикл.
func TestReRegistrationHappensAtMostOnce(t *testing.T) {
	posts := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "POST":
			posts++
			w.Write([]byte(badRegBody)) // API упорно отдаёт негодный диапазон
		case "PATCH":
			w.Write([]byte(`{"warp_enabled":true}`))
		default:
			w.Write([]byte(badRegBody))
		}
	}))
	defer s.Close()
	c := &Client{BaseURL: s.URL, HTTP: s.Client()}
	p := filepath.Join(t.TempDir(), "device.json")

	bad := &Device{ID: "dev1", Token: "t", PrivateKey: "k", Tunnel: TunnelWG,
		Endpoint: Endpoint{V4: "162.159.192.9", Ports: []int{2408}}}
	bad.Save(p)

	if _, created, err := c.Ensure(context.Background(), p); err != nil || !created || posts != 1 {
		t.Fatalf("первая попытка: created=%v err=%v posts=%d", created, err, posts)
	}
	// Адрес снова негодный — но второй регистрации быть не должно.
	for i := 0; i < 3; i++ {
		if _, created, err := c.Ensure(context.Background(), p); err != nil || created {
			t.Fatalf("прогон %d: created=%v err=%v", i, created, err)
		}
	}
	if posts != 1 {
		t.Fatalf("регистраций всего должно быть 1, а их %d — лимит Cloudflare сгорит", posts)
	}
}

func TestReservedRejectsBadClientID(t *testing.T) {
	d := &Device{ClientID: "!!"}
	if _, err := d.Reserved(); err == nil {
		t.Fatal("want error")
	}
}
