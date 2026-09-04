// Package voiceprobe меряет, что происходит с голосовым трафиком Дискорда.
//
// ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ ПОДБОРА ПО ДОМЕНУ. Там всё стоит на имени: имя вводит
// человек, имя же меняется в контроле, и разница «наше имя молчит, нейтральное
// отвечает» и есть измерение. У голоса имени НЕТ ВООБЩЕ — в боевом профиле так
// и записано, hostkey=z2k_nohost_key. Значит рушатся обе половины: и откуда
// брать цель, и с чем сравнивать.
//
// ОТКУДА ЦЕЛЬ. Голосовой сервер выдаётся на сессию, в публичном DNS его нет
// (проверено 04.09: discord.media резолвится, russiaNNNN.discord.media — нет).
// Зашить нечего, вписать человеку нечего. Остаётся одно: взять адрес из ЖИВОГО
// разговора, из conntrack роутера. Поэтому у этого замера не поле ввода, а
// требование «сначала позвони».
//
// С ЧЕМ СРАВНИВАТЬ. Вместо нейтрального имени — три слоя, у каждого свой
// оракул: публичный STUN-сервер доказывает, что UDP на канале вообще ходит;
// STUN на сам голосовой адрес доказывает, что конечная точка достижима; и
// только потом меряется то, ради чего всё затевалось, — выживает ли поток.
//
// ПОЧЕМУ ИМЕННО STUN. У него настоящий ответ, а не тишина: сервер возвращает
// наш же адрес, и совпадение идентификатора транзакции доказывает, что ответил
// именно он. После QUIC, где оракул пришлось выцарапывать из остаточной
// блокировки, это подарок.
package voiceprobe

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"net"
)

// Константы протокола (RFC 5389 §6, §15.2).
const (
	stunBindingRequest  = 0x0001
	stunBindingResponse = 0x0101
	stunMagicCookie     = 0x2112A442
	attrXorMappedAddr   = 0x0020
	stunHeaderLen       = 20
)

// BindingRequest собирает запрос STUN и возвращает его вместе с
// идентификатором транзакции: по нему потом опознаётся ответ.
func BindingRequest() (pkt []byte, txID [12]byte) {
	_, _ = rand.Read(txID[:])
	pkt = make([]byte, 0, stunHeaderLen)
	pkt = binary.BigEndian.AppendUint16(pkt, stunBindingRequest)
	pkt = binary.BigEndian.AppendUint16(pkt, 0) // длина атрибутов
	pkt = binary.BigEndian.AppendUint32(pkt, stunMagicCookie)
	pkt = append(pkt, txID[:]...)
	return pkt, txID
}

// ParseBindingResponse проверяет, что пакет — ответ на НАШ запрос, и достаёт
// адрес, который сервер увидел.
//
// Сверка идентификатора транзакции обязательна. Без неё за ответ сошёл бы любой
// мусор, прилетевший на порт, — ровно та ошибка, которую пришлось разбирать в
// QUIC-зонде с чужим Initial.
func ParseBindingResponse(pkt []byte, txID [12]byte) (net.IP, int, error) {
	if len(pkt) < stunHeaderLen {
		return nil, 0, errors.New("voiceprobe: пакет короче заголовка STUN")
	}
	if binary.BigEndian.Uint16(pkt[0:]) != stunBindingResponse {
		return nil, 0, errors.New("voiceprobe: не ответ на Binding Request")
	}
	if binary.BigEndian.Uint32(pkt[4:]) != stunMagicCookie {
		return nil, 0, errors.New("voiceprobe: нет магической метки STUN")
	}
	for i := 0; i < 12; i++ {
		if pkt[8+i] != txID[i] {
			return nil, 0, errors.New("voiceprobe: чужой идентификатор транзакции")
		}
	}
	attrsLen := int(binary.BigEndian.Uint16(pkt[2:]))
	if stunHeaderLen+attrsLen > len(pkt) {
		return nil, 0, errors.New("voiceprobe: объявленная длина атрибутов больше пакета")
	}

	b := pkt[stunHeaderLen : stunHeaderLen+attrsLen]
	for len(b) >= 4 {
		typ := binary.BigEndian.Uint16(b[0:])
		ln := int(binary.BigEndian.Uint16(b[2:]))
		if 4+ln > len(b) {
			break
		}
		if typ == attrXorMappedAddr {
			ip, port, err := parseXorMapped(b[4:4+ln], txID)
			return ip, port, err
		}
		// Атрибуты выровнены по четыре байта.
		step := 4 + ln
		if pad := ln % 4; pad != 0 {
			step += 4 - pad
		}
		if step > len(b) {
			break
		}
		b = b[step:]
	}
	// Ответ есть, адреса в нём нет. Для оракула этого достаточно: сервер
	// ответил именно нам, значит датаграмма дошла и вернулась.
	return nil, 0, nil
}

// parseXorMapped разбирает XOR-MAPPED-ADDRESS (RFC 5389 §15.2): адрес и порт
// поксорены с магической меткой, чтобы их не портили NAT-ы, переписывающие
// адреса в теле пакета.
func parseXorMapped(a []byte, txID [12]byte) (net.IP, int, error) {
	if len(a) < 8 {
		return nil, 0, errors.New("voiceprobe: короткий XOR-MAPPED-ADDRESS")
	}
	port := int(binary.BigEndian.Uint16(a[2:]) ^ uint16(stunMagicCookie>>16))
	switch a[1] {
	case 0x01: // IPv4
		ip := make(net.IP, 4)
		binary.BigEndian.PutUint32(ip, binary.BigEndian.Uint32(a[4:])^stunMagicCookie)
		return ip, port, nil
	case 0x02: // IPv6
		if len(a) < 20 {
			return nil, 0, errors.New("voiceprobe: короткий адрес IPv6")
		}
		key := make([]byte, 0, 16)
		key = binary.BigEndian.AppendUint32(key, stunMagicCookie)
		key = append(key, txID[:]...)
		ip := make(net.IP, 16)
		for i := 0; i < 16; i++ {
			ip[i] = a[4+i] ^ key[i]
		}
		return ip, port, nil
	}
	return nil, 0, errors.New("voiceprobe: неизвестное семейство адресов")
}
