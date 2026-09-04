// Package quicprobe собирает и разбирает QUIC Initial руками.
//
// ЗАЧЕМ РУКАМИ, А НЕ ГОТОВЫМ СТЕКОМ. Мерить надо не «устанавливается ли
// соединение», а как коробка провайдера РАЗБИРАЕТ наш пакет. Значит нужен
// контроль над каждым полем — версией, длинами идентификаторов, числом кадров
// CRYPTO и их смещениями, паддингом, фиксированным битом. Готовая библиотека
// такого не даёт: она на то и библиотека, чтобы собирать корректные пакеты.
// Заодно go.mod остаётся с тремя зависимостями — всё нужное лежит в stdlib
// начиная с Go 1.24 (crypto/hkdf) и Go 1.21 (crypto/tls QUICClient).
//
// ПОЧЕМУ ЭТО ВООБЩЕ РАБОТАЕТ. Криптография Initial публична, и в этом весь
// смысл упражнения: ключи выводятся из DCID, который лежит в заголовке
// открытым текстом (RFC 9001 §5.2). Расшифровать клиентский Initial может кто
// угодно на пути — коробка провайдера ровно этим и занимается, чтобы достать
// SNI. Нам та же публичность даёт ОРАКУЛ: ответ настоящего сервера мы
// отличаем от чужой инъекции тем, что он раскрывается ключами, выведенными ИЗ
// НАШЕГО DCID. Замер 04.09 показал, зачем это нужно: на youtube-именах
// прилетал «Initial» с нулевым DCID и 20-байтовым SCID, который серверными
// ключами не раскрывается вовсе. Считать любой входящий пакет ответом нельзя.
//
// Корректность собранного пакета проверяется не на глаз: initial_test.go
// прогоняет тест-векторы RFC 9001 Appendix A и сверяет результат побайтно.
package quicprobe

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
)

// Version — номер версии QUIC в поле заголовка.
type Version uint32

const (
	// V1 — RFC 9000, единственная версия, которую сегодня шлют браузеры.
	V1 Version = 0x00000001
	// V2 — RFC 9369. Отличается солью и метками вывода ключей, поэтому
	// коробка, знающая только v1, такой Initial не расшифрует. Для замера это
	// отдельный вопрос к коробке, а не экзотика: в статье USENIX Sec'25 по GFW
	// v2-пакеты не блокировались вовсе.
	V2 Version = 0x6b3343cf
)

// Соли вывода начальных ключей. Значения нормативные: RFC 9001 §5.2 для v1,
// RFC 9369 §3.3.1 для v2.
var (
	saltV1 = []byte{
		0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
		0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
	}
	saltV2 = []byte{
		0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93,
		0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb, 0xf9, 0xbd, 0x2e, 0xd9,
	}
)

// Тип пакета в длинном заголовке. В v2 типы намеренно перенумерованы
// (RFC 9369 §3.2) — ещё одна ловушка для коробки, зашитой на v1.
const (
	longTypeInitialV1 = 0x00
	longTypeRetryV1   = 0x03
	longTypeInitialV2 = 0x01
	longTypeRetryV2   = 0x00
)

func salt(v Version) []byte {
	if v == V2 {
		return saltV2
	}
	return saltV1
}

func labels(v Version) (key, iv, hp string) {
	if v == V2 {
		return "quicv2 key", "quicv2 iv", "quicv2 hp"
	}
	return "quic key", "quic iv", "quic hp"
}

func initialType(v Version) byte {
	if v == V2 {
		return longTypeInitialV2
	}
	return longTypeInitialV1
}

func retryType(v Version) byte {
	if v == V2 {
		return longTypeRetryV2
	}
	return longTypeRetryV1
}

// hkdfExpandLabel — HKDF-Expand-Label из TLS 1.3 (RFC 8446 §7.1). QUIC
// использует его без изменений, контекст всегда пустой.
func hkdfExpandLabel(secret []byte, label string, length int) ([]byte, error) {
	full := "tls13 " + label
	info := make([]byte, 0, 2+1+len(full)+1)
	info = binary.BigEndian.AppendUint16(info, uint16(length))
	info = append(info, byte(len(full)))
	info = append(info, full...)
	info = append(info, 0) // пустой контекст
	return hkdf.Expand(sha256.New, secret, string(info), length)
}

// keySet — материал защиты одного направления.
type keySet struct {
	key []byte // AES-128-GCM
	iv  []byte // 12 байт, XOR'ится с номером пакета
	hp  []byte // ключ защиты заголовка, AES-ECB
}

// deriveKeys выводит ключи обоих направлений из DCID, выбранного КЛИЕНТОМ.
//
// Важно: серверные ключи выводятся из того же самого DCID, а не из
// идентификатора, который сервер выберет себе. Поэтому ответ сервера мы можем
// расшифровать, зная только то, что послали сами, — на этом стоит весь оракул.
func deriveKeys(dcid []byte, v Version) (client, server keySet, err error) {
	initialSecret, err := hkdf.Extract(sha256.New, dcid, salt(v))
	if err != nil {
		return client, server, err
	}
	kl, il, hl := labels(v)
	derive := func(who string) (keySet, error) {
		s, err := hkdfExpandLabel(initialSecret, who, 32)
		if err != nil {
			return keySet{}, err
		}
		var ks keySet
		if ks.key, err = hkdfExpandLabel(s, kl, 16); err != nil {
			return keySet{}, err
		}
		if ks.iv, err = hkdfExpandLabel(s, il, 12); err != nil {
			return keySet{}, err
		}
		if ks.hp, err = hkdfExpandLabel(s, hl, 16); err != nil {
			return keySet{}, err
		}
		return ks, nil
	}
	if client, err = derive("client in"); err != nil {
		return client, server, err
	}
	server, err = derive("server in")
	return client, server, err
}

// appendVarint дописывает число в переменноразрядной кодировке QUIC
// (RFC 9000 §16): два старших бита задают длину поля.
func appendVarint(b []byte, v uint64) []byte {
	switch {
	case v <= 63:
		return append(b, byte(v))
	case v <= 16383:
		return binary.BigEndian.AppendUint16(b, uint16(v)|0x4000)
	case v <= 1073741823:
		return binary.BigEndian.AppendUint32(b, uint32(v)|0x80000000)
	default:
		return binary.BigEndian.AppendUint64(b, v|0xc000000000000000)
	}
}

// readVarint читает переменноразрядное число, возвращая его и число съеденных
// байт. n == 0 значит, что данных не хватило.
func readVarint(b []byte) (val uint64, n int) {
	if len(b) == 0 {
		return 0, 0
	}
	size := 1 << (b[0] >> 6)
	if len(b) < size {
		return 0, 0
	}
	val = uint64(b[0] & 0x3f)
	for i := 1; i < size; i++ {
		val = val<<8 | uint64(b[i])
	}
	return val, size
}

// CryptoFrame — один кадр CRYPTO. Несколько кадров с разными смещениями и есть
// «нарезка» ClientHello: точный аналог разреза TCP-потока, и единственный
// приём, который ломает РАЗБОР, а не сигнатуру. По данным USENIX Sec'25 GFW
// такие кадры не пересобирает; Firefox 137 шлёт их по умолчанию.
type CryptoFrame struct {
	Offset uint64
	Data   []byte
}

// Initial — описание клиентского Initial, который мы собираемся послать.
// Каждое поле здесь — отдельный вопрос к коробке, поэтому умолчаний по-минимуму:
// вызывающий обязан сказать, что именно он меряет.
type Initial struct {
	Version Version
	DCID    []byte
	SCID    []byte
	Token   []byte

	PacketNumber uint32
	// PNLen — 1..4. RFC не требует конкретной длины, а коробка может быть
	// зашита на четырёхбайтовую: в таблице GFW однобайтовый номер блокировался.
	PNLen int

	Crypto []CryptoFrame
	// DatagramLen — добить PADDING до этой длины. Клиент ОБЯЗАН слать не
	// меньше 1200 байт (RFC 9000 §14.1), иначе сервер выбросит пакет молча.
	// Ноль — не добивать: так проверяется, есть ли у коробки своё правило
	// минимальной длины (у GFW его нет, срабатывает и на 137 байтах).
	DatagramLen int

	// ClearFixedBit сбрасывает второй по старшинству бит. По RFC 9000 он
	// обязан быть единицей, и коробка обычно по нему и отличает QUIC от
	// прочего UDP; RFC 9287 разрешает его гриз. Отдельный вопрос к коробке.
	ClearFixedBit bool
}

// Marshal собирает готовую датаграмму: заголовок, зашифрованный payload,
// защита заголовка.
func (p Initial) Marshal() ([]byte, error) {
	if len(p.DCID) > 255 || len(p.SCID) > 255 {
		return nil, errors.New("quicprobe: идентификатор длиннее 255 байт")
	}
	if p.PNLen < 1 || p.PNLen > 4 {
		return nil, fmt.Errorf("quicprobe: длина номера пакета %d вне 1..4", p.PNLen)
	}
	client, _, err := deriveKeys(p.DCID, p.Version)
	if err != nil {
		return nil, err
	}

	// Полезная нагрузка: кадры CRYPTO, затем PADDING (нулевые байты) до
	// нужного размера датаграммы.
	payload := make([]byte, 0, 1200)
	for _, f := range p.Crypto {
		payload = append(payload, 0x06) // тип кадра CRYPTO
		payload = appendVarint(payload, f.Offset)
		payload = appendVarint(payload, uint64(len(f.Data)))
		payload = append(payload, f.Data...)
	}

	first := byte(0xc0) | initialType(p.Version)<<4 | byte(p.PNLen-1)
	if p.ClearFixedBit {
		first &^= 0x40
	}

	// Длина заголовка нужна до того, как известен паддинг: поле length
	// объявляет номер пакета плюс шифротекст плюс тег, а сам паддинг входит в
	// шифротекст. Поэтому сперва считаем всё, кроме паддинга, потом добираем.
	hdrLen := 1 + 4 + 1 + len(p.DCID) + 1 + len(p.SCID)
	hdrLen += len(appendVarint(nil, uint64(len(p.Token)))) + len(p.Token)
	// Поле length переменной длины, но при любом разумном размере датаграммы
	// оно двухбайтовое; фиксируем это явно, чтобы арифметика паддинга сошлась.
	const lenFieldSize = 2
	hdrLen += lenFieldSize + p.PNLen

	if p.DatagramLen > 0 {
		want := p.DatagramLen - hdrLen - 16 // 16 — тег AEAD
		if want < len(payload) {
			return nil, fmt.Errorf("quicprobe: датаграмма %d байт мала для %d байт кадров",
				p.DatagramLen, len(payload))
		}
		payload = append(payload, make([]byte, want-len(payload))...)
	}

	length := uint64(p.PNLen + len(payload) + 16)
	if length > 16383 {
		return nil, fmt.Errorf("quicprobe: длина %d не влезает в двухбайтовое поле", length)
	}

	hdr := make([]byte, 0, hdrLen)
	hdr = append(hdr, first)
	hdr = binary.BigEndian.AppendUint32(hdr, uint32(p.Version))
	hdr = append(hdr, byte(len(p.DCID)))
	hdr = append(hdr, p.DCID...)
	hdr = append(hdr, byte(len(p.SCID)))
	hdr = append(hdr, p.SCID...)
	hdr = appendVarint(hdr, uint64(len(p.Token)))
	hdr = append(hdr, p.Token...)
	hdr = binary.BigEndian.AppendUint16(hdr, uint16(length)|0x4000)
	pnOffset := len(hdr)
	hdr = appendPacketNumber(hdr, p.PacketNumber, p.PNLen)

	sealed, err := seal(client, payload, hdr, p.PacketNumber)
	if err != nil {
		return nil, err
	}
	pkt := append(hdr, sealed...)
	if err := applyHeaderProtection(pkt, client.hp, pnOffset, p.PNLen, true); err != nil {
		return nil, err
	}
	return pkt, nil
}

func appendPacketNumber(b []byte, pn uint32, n int) []byte {
	for i := n - 1; i >= 0; i-- {
		b = append(b, byte(pn>>(8*i)))
	}
	return b
}

// seal шифрует нагрузку. AAD — весь незащищённый заголовок вплоть до номера
// пакета включительно; nonce — вектор инициализации, поксоренный с номером,
// выровненным вправо (RFC 9001 §5.3).
func seal(ks keySet, payload, aad []byte, pn uint32) ([]byte, error) {
	block, err := aes.NewCipher(ks.key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return aead.Seal(nil, nonce(ks.iv, pn), payload, aad), nil
}

func open(ks keySet, ct, aad []byte, pn uint32) ([]byte, error) {
	block, err := aes.NewCipher(ks.key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return aead.Open(nil, nonce(ks.iv, pn), ct, aad)
}

func nonce(iv []byte, pn uint32) []byte {
	n := make([]byte, len(iv))
	copy(n, iv)
	for i := 0; i < 4; i++ {
		n[len(n)-1-i] ^= byte(pn >> (8 * i))
	}
	return n
}

// applyHeaderProtection ксорит первый байт и номер пакета маской, выведенной из
// шифротекста. Операция симметрична, поэтому одна функция и на защиту, и на
// снятие; различается только то, откуда берётся длина номера (при снятии она
// сама зашифрована и становится известна лишь после расшифровки первого байта).
func applyHeaderProtection(pkt, hpKey []byte, pnOffset, pnLen int, longHeader bool) error {
	sampleOff := pnOffset + 4
	if len(pkt) < sampleOff+16 {
		return errors.New("quicprobe: пакет короче, чем нужно для выборки защиты заголовка")
	}
	block, err := aes.NewCipher(hpKey)
	if err != nil {
		return err
	}
	mask := make([]byte, 16)
	block.Encrypt(mask, pkt[sampleOff:sampleOff+16])
	if longHeader {
		pkt[0] ^= mask[0] & 0x0f
	} else {
		pkt[0] ^= mask[0] & 0x1f
	}
	for i := 0; i < pnLen; i++ {
		pkt[pnOffset+i] ^= mask[1+i]
	}
	return nil
}
