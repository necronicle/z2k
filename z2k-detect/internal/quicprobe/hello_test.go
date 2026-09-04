package quicprobe

import (
	"bytes"
	"testing"
)

// Приветствие должно (а) содержать имя, по которому режут, и (б) помещаться в
// одну датаграмму. Второе — не косметика: приветствие длиннее 1200 байт само
// разъезжается на две датаграммы, а это отдельный приём обхода, и он обязан
// включаться нашим решением, а не набором кривых по умолчанию.
func TestClientHelloFitsOneDatagram(t *testing.T) {
	scid := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	hello, err := ClientHello("rutracker.org", scid)
	if err != nil {
		t.Fatalf("ClientHello: %v", err)
	}
	if !bytes.Contains(hello, []byte("rutracker.org")) {
		t.Error("в приветствии нет имени")
	}
	// Заголовок Initial с восьмибайтовыми идентификаторами занимает 22 байта,
	// кадр CRYPTO — до 4, тег AEAD — 16.
	if room := 1200 - 22 - 4 - 16; len(hello) > room {
		t.Errorf("приветствие %d байт, в датаграмму влезает %d", len(hello), room)
	}
	if !bytes.Contains(hello, []byte("h3")) {
		t.Error("в приветствии нет ALPN h3 — сервер ответит отказом, и это спутают с блокировкой")
	}
}

// Зонд согласования версии не должен содержать ничего, по чему можно принять
// решение о блокировке: в этом весь его смысл как контроля пути.
func TestVersionNegotiationProbeIsContentFree(t *testing.T) {
	p := versionNegotiationProbe([]byte("12345678"), []byte("abcdefgh"), 1200)
	if len(p) != 1200 {
		t.Fatalf("длина %d, ожидалось 1200", len(p))
	}
	if p[1] == 0 && p[2] == 0 && p[3] == 0 && p[4] == 1 {
		t.Error("версия совпала с v1 — коробка разберёт зонд как обычный Initial")
	}
	// Никакого TLS внутри: ни одного байта, похожего на начало ClientHello.
	if bytes.Contains(p[22:], []byte{0x01, 0x00, 0x00}) {
		t.Error("в зонде нашлось нечто похожее на ClientHello")
	}
}
