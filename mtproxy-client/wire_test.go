package main

import (
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"net"
	"testing"
	"time"
)

// Тесты формата кадра туннеля.
//
// Это НЕ про MTProto — его здесь нет вовсе. Клиент перехватывает REDIRECT'нутые
// соединения и мультиплексирует их в один WebSocket до нашего релея; протокол
// внутри — наш собственный, и снаружи его никто не валидирует. До 2026-08-08
// покрытие модуля было ровно 0.0%.
//
// Цена ошибки в этом слое известна и уже реализовывалась: молчаливая смерть
// Telegram у всех сразу. Поэтому проверяем не «работает ли», а держим ФОРМАТ:
// три байта заголовка, порядок полей, границу «пустой payload / обрезанный
// кадр» и то, что вторая сторона (vps-relay) разберёт ровно это.

// --- заголовок кадра ---------------------------------------------------------

func TestMuxFrameRoundTrip(t *testing.T) {
	cases := []struct {
		name     string
		streamID uint16
		msgType  byte
		payload  []byte
	}{
		{"обычный DATA", 1, 0x02, []byte("hello")},
		{"нулевой stream (служебный)", 0, 0x00, []byte{1, 2, 3}},
		{"максимальный stream id", 65535, 0x03, []byte{0xff}},
		{"пустой payload", 7, 0x05, nil},
		{"payload с нулевыми байтами", 9, 0x02, []byte{0, 0, 0}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			raw := encodeMuxFrame(c.streamID, c.msgType, c.payload)
			if len(raw) != 3+len(c.payload) {
				t.Fatalf("длина кадра %d, ожидали %d", len(raw), 3+len(c.payload))
			}
			f, err := decodeMuxFrame(raw)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if f.StreamID != c.streamID {
				t.Errorf("streamID %d, ожидали %d", f.StreamID, c.streamID)
			}
			if f.MsgType != c.msgType {
				t.Errorf("msgType %#x, ожидали %#x", f.MsgType, c.msgType)
			}
			if string(f.Payload) != string(c.payload) {
				t.Errorf("payload %v, ожидали %v", f.Payload, c.payload)
			}
		})
	}
}

// Порядок байтов в streamID — big-endian. Если он поедет, релей увидит чужой
// стрим и данные уйдут не в то соединение, причём без единой ошибки.
func TestMuxFrameStreamIDIsBigEndian(t *testing.T) {
	raw := encodeMuxFrame(0x0102, 0x02, nil)
	if raw[0] != 0x01 || raw[1] != 0x02 {
		t.Fatalf("ожидали big-endian 01 02, получили %02x %02x", raw[0], raw[1])
	}
	if raw[2] != 0x02 {
		t.Fatalf("тип сообщения должен быть третьим байтом, получили %02x", raw[2])
	}
}

// Граница «пустой payload» против «обрезанный кадр» держится на одном
// сравнении. Три байта — это валидный кадр без нагрузки; два — мусор.
func TestDecodeMuxFrameBoundary(t *testing.T) {
	if _, err := decodeMuxFrame([]byte{0, 1, 2}); err != nil {
		t.Errorf("три байта — валидный кадр без payload, получили ошибку: %v", err)
	}
	for _, short := range [][]byte{nil, {}, {0}, {0, 1}} {
		if _, err := decodeMuxFrame(short); err == nil {
			t.Errorf("кадр из %d байт обязан отвергаться", len(short))
		}
	}
}

// --- CONNECT payload ---------------------------------------------------------

// parseConnectLikeRelay повторяет разбор из vps-relay/main.go.
//
// Держим копию намеренно: модули собираются отдельно, импортировать нечего, а
// расхождение форматов между тем, что клиент кладёт, и тем, что релей читает,
// иначе обнаружится только в проде — соединением, которое ушло не туда.
func parseConnectLikeRelay(p []byte) (addr string, port int, ok bool) {
	if len(p) < 1 {
		return "", 0, false
	}
	switch p[0] {
	case 1: // IPv4
		if len(p) < 7 {
			return "", 0, false
		}
		return net.IP(p[1:5]).String(), int(binary.BigEndian.Uint16(p[5:7])), true
	case 4: // IPv6
		if len(p) < 19 {
			return "", 0, false
		}
		return net.IP(p[1:17]).String(), int(binary.BigEndian.Uint16(p[17:19])), true
	}
	return "", 0, false
}

func TestConnectPayloadReadableByRelay(t *testing.T) {
	cases := []struct {
		ip   string
		port int
	}{
		{"149.154.167.51", 443},        // Telegram DC, v4
		{"91.108.56.130", 80},          // другой DC
		{"2001:b28:f23d:f001::a", 443}, // Telegram, v6
		{"10.0.0.1", 65535},            // граничный порт
		{"127.0.0.1", 1},               // минимальный порт
	}
	for _, c := range cases {
		ip := net.ParseIP(c.ip)
		if ip == nil {
			t.Fatalf("тест сломан: %q не парсится", c.ip)
		}
		raw := encodeConnectPayload(ip, c.port)
		addr, port, ok := parseConnectLikeRelay(raw)
		if !ok {
			t.Errorf("%s:%d — релей не разобрал payload", c.ip, c.port)
			continue
		}
		if !net.ParseIP(addr).Equal(ip) {
			t.Errorf("адрес %s, ожидали %s", addr, c.ip)
		}
		if port != c.port {
			t.Errorf("порт %d, ожидали %d", port, c.port)
		}
	}
}

func TestConnectPayloadLengths(t *testing.T) {
	v4 := encodeConnectPayload(net.ParseIP("1.2.3.4"), 443)
	if len(v4) != 7 || v4[0] != 1 {
		t.Errorf("IPv4 payload: длина %d тип %d, ожидали 7 и 1", len(v4), v4[0])
	}
	v6 := encodeConnectPayload(net.ParseIP("2001:b28:f23d::1"), 443)
	if len(v6) != 19 || v6[0] != 4 {
		t.Errorf("IPv6 payload: длина %d тип %d, ожидали 19 и 4", len(v6), v6[0])
	}
	// IPv4-mapped адрес обязан ехать как v4: релей по типу 4 ждёт 16 байт,
	// и лишние 12 нулей сделали бы из 1.2.3.4 совсем другой адрес.
	mapped := encodeConnectPayload(net.ParseIP("::ffff:1.2.3.4"), 443)
	if len(mapped) != 7 || mapped[0] != 1 {
		t.Errorf("IPv4-mapped должен кодироваться как v4, получили длину %d тип %d",
			len(mapped), mapped[0])
	}
}

// --- аутентификация ----------------------------------------------------------

func TestComputeAuthHMACIsStableAndKeyed(t *testing.T) {
	a := computeAuthHMAC("secret-one")
	b := computeAuthHMAC("secret-one")
	c := computeAuthHMAC("secret-two")
	if len(a) != 32 {
		t.Fatalf("HMAC-SHA256 должен быть 32 байта, получили %d", len(a))
	}
	if string(a) != string(b) {
		t.Error("один и тот же секрет обязан давать один и тот же HMAC")
	}
	if string(a) == string(c) {
		t.Error("разные секреты обязаны давать разный HMAC")
	}
}

// muxAUTHID: [install_id:16][timestamp:8 BE][sig:64] = 88 байт,
// подпись — над первыми 24 байтами. Релей проверяет ровно это.
func TestAuthPayloadShapeAndSignature(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("ключ не сгенерировался: %v", err)
	}
	const idHex = "0123456789abcdef0123456789abcdef"
	id := &relayIdentity{InstallID: idHex, priv: priv}

	before := time.Now().Unix()
	p := id.authPayload()
	after := time.Now().Unix()

	if len(p) != 88 {
		t.Fatalf("длина payload %d, ожидали 88", len(p))
	}
	idb, _ := hex.DecodeString(idHex)
	if string(p[0:16]) != string(idb) {
		t.Error("первые 16 байт должны быть install_id в бинарном виде")
	}
	ts := int64(binary.BigEndian.Uint64(p[16:24]))
	if ts < before || ts > after {
		t.Errorf("метка времени %d вне окна [%d, %d]", ts, before, after)
	}
	if !ed25519.Verify(pub, p[0:24], p[24:88]) {
		t.Error("подпись не проверяется над первыми 24 байтами")
	}
	// Порча любого байта подписываемой части обязана ломать проверку.
	bad := make([]byte, 88)
	copy(bad, p)
	bad[0] ^= 0xff
	if ed25519.Verify(pub, bad[0:24], bad[24:88]) {
		t.Error("подпись прошла на изменённом install_id")
	}
}

// --- служебное ---------------------------------------------------------------

func TestDeriveRegisterURL(t *testing.T) {
	cases := map[string]string{
		"wss://relay.example/ws":      "https://relay.example/register",
		"ws://relay.example/ws":       "http://relay.example/register",
		"wss://1.2.3.4.nip.io/ws":     "https://1.2.3.4.nip.io/register",
		"wss://relay.example":         "https://relay.example/register",
		"wss://relay.example/":        "https://relay.example/register",
		"wss://relay.example:8443/ws": "https://relay.example:8443/register",
	}
	for in, want := range cases {
		if got := deriveRegisterURL(in); got != want {
			t.Errorf("deriveRegisterURL(%q) = %q, ожидали %q", in, got, want)
		}
	}
}

func TestValidInstallIDClient(t *testing.T) {
	valid := []string{
		"0123456789abcdef0123456789abcdef",
		"ffffffffffffffffffffffffffffffff",
		"00000000000000000000000000000000",
	}
	for _, s := range valid {
		if !validInstallIDClient(s) {
			t.Errorf("%q должен быть валидным", s)
		}
	}
	invalid := map[string]string{
		"":                                  "пустой",
		"0123456789abcdef0123456789abcde":   "31 символ",
		"0123456789abcdef0123456789abcdef0": "33 символа",
		"0123456789ABCDEF0123456789abcdef":  "заглавные hex",
		"0123456789abcdef0123456789abcdeg":  "не-hex символ",
		"0123456789abcdef 123456789abcdef":  "пробел",
	}
	for s, why := range invalid {
		if validInstallIDClient(s) {
			t.Errorf("%q (%s) не должен проходить", s, why)
		}
	}
}
