package voiceprobe

import (
	"encoding/binary"
	"net"
	"testing"
)

// Запрос обязан быть ровно тем, что признают серверы: тип, длина, магическая
// метка. Ошибка тут не заметна в поле — сервер молча промолчит, а мы объявим
// «режут», хотя виноват собственный пакет.
func TestBindingRequestShape(t *testing.T) {
	pkt, tx := BindingRequest()
	if len(pkt) != stunHeaderLen {
		t.Fatalf("длина %d, ожидалось %d", len(pkt), stunHeaderLen)
	}
	if got := binary.BigEndian.Uint16(pkt[0:]); got != stunBindingRequest {
		t.Errorf("тип %#04x, ожидался %#04x", got, stunBindingRequest)
	}
	if got := binary.BigEndian.Uint16(pkt[2:]); got != 0 {
		t.Errorf("длина атрибутов %d, ожидался 0", got)
	}
	if got := binary.BigEndian.Uint32(pkt[4:]); got != stunMagicCookie {
		t.Errorf("метка %#08x, ожидалась %#08x", got, stunMagicCookie)
	}
	var zero [12]byte
	if tx == zero {
		t.Error("идентификатор транзакции нулевой — ответ нечем будет опознать")
	}
}

// Два запроса подряд обязаны получить РАЗНЫЕ идентификаторы: иначе ответ на
// прошлый зонд засчитается за ответ на текущий, и замер поплывёт.
func TestBindingRequestIDsDiffer(t *testing.T) {
	_, a := BindingRequest()
	_, b := BindingRequest()
	if a == b {
		t.Fatal("идентификаторы транзакций совпали")
	}
}

// mkResponse собирает ответ сервера с XOR-MAPPED-ADDRESS.
func mkResponse(tx [12]byte, ip net.IP, port int) []byte {
	attr := make([]byte, 0, 12)
	attr = binary.BigEndian.AppendUint16(attr, attrXorMappedAddr)
	attr = binary.BigEndian.AppendUint16(attr, 8)
	attr = append(attr, 0x00, 0x01) // reserved, семейство IPv4
	attr = binary.BigEndian.AppendUint16(attr, uint16(port)^uint16(stunMagicCookie>>16))
	v4 := ip.To4()
	attr = binary.BigEndian.AppendUint32(attr, binary.BigEndian.Uint32(v4)^stunMagicCookie)

	out := make([]byte, 0, stunHeaderLen+len(attr))
	out = binary.BigEndian.AppendUint16(out, stunBindingResponse)
	out = binary.BigEndian.AppendUint16(out, uint16(len(attr)))
	out = binary.BigEndian.AppendUint32(out, stunMagicCookie)
	out = append(out, tx[:]...)
	return append(out, attr...)
}

// Адрес обязан разбираться обратно: он поксорен с меткой именно затем, чтобы
// его не портили NAT-ы, переписывающие адреса в теле пакета.
func TestParseXorMappedRoundTrip(t *testing.T) {
	_, tx := BindingRequest()
	want, wantPort := net.IPv4(203, 0, 113, 7), 51234
	ip, port, err := ParseBindingResponse(mkResponse(tx, want, wantPort), tx)
	if err != nil {
		t.Fatalf("разбор: %v", err)
	}
	if !ip.Equal(want) {
		t.Errorf("адрес %v, ожидался %v", ip, want)
	}
	if port != wantPort {
		t.Errorf("порт %d, ожидался %d", port, wantPort)
	}
}

// ГЛАВНОЕ ПРАВИЛО ОРАКУЛА: чужой пакет не ответ.
//
// В QUIC-зонде это уже стоило крови — на порт прилетал «Initial», который не
// раскрывался нашими ключами, и принять его за ответ значило объявить блокировку
// обходом. Здесь то же самое ловится сверкой идентификатора транзакции.
func TestForeignResponseRejected(t *testing.T) {
	_, mine := BindingRequest()
	_, other := BindingRequest()
	if _, _, err := ParseBindingResponse(mkResponse(other, net.IPv4(1, 2, 3, 4), 1), mine); err == nil {
		t.Fatal("ответ с чужим идентификатором транзакции засчитан за наш")
	}
	if _, _, err := ParseBindingResponse([]byte("мусор"), mine); err == nil {
		t.Fatal("мусор засчитан за ответ")
	}
	// Запрос — не ответ, даже со своим идентификатором.
	req, tx := BindingRequest()
	if _, _, err := ParseBindingResponse(req, tx); err == nil {
		t.Fatal("собственный запрос засчитан за ответ")
	}
}

// Битая длина атрибутов не должна ронять разбор: пакет прилетает из сети, и
// доверять его полям нельзя.
func TestTruncatedAttributesDoNotPanic(t *testing.T) {
	_, tx := BindingRequest()
	pkt := mkResponse(tx, net.IPv4(1, 1, 1, 1), 1)
	binary.BigEndian.PutUint16(pkt[2:], 9999) // длина больше пакета
	if _, _, err := ParseBindingResponse(pkt, tx); err == nil {
		t.Error("объявленная длина больше пакета принята молча")
	}
}
