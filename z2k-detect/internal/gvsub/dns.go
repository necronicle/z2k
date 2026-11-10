package gvsub

// Разбор ответа DNS, который роутер отдаёт устройству: IP-заголовок (v4 или
// v6), UDP, затем сообщение DNS. Нужны только адреса из записей A и AAAA и
// признак, что ответ про имя googlevideo.

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"strings"
)

// Suffix — исходное семейство видеокэша; rr-кэши c.youtube.com см. IsTarget.
const Suffix = "googlevideo.com"

var errShort = errors.New("короткий пакет")

// udpPayload возвращает полезную нагрузку UDP из IP-пакета.
func udpPayload(pkt []byte) ([]byte, error) {
	if len(pkt) < 1 {
		return nil, errShort
	}
	var off int
	switch pkt[0] >> 4 {
	case 4:
		if len(pkt) < 20 {
			return nil, errShort
		}
		if pkt[9] != 17 {
			return nil, errors.New("не UDP")
		}
		off = int(pkt[0]&0x0f) * 4
	case 6:
		if len(pkt) < 40 {
			return nil, errShort
		}
		// Заголовки расширения в ответах DNS не встречаются; если есть — пропускаем пакет.
		if pkt[6] != 17 {
			return nil, errors.New("не UDP")
		}
		off = 40
	default:
		return nil, errors.New("не IP")
	}
	if len(pkt) < off+8 {
		return nil, errShort
	}
	return pkt[off+8:], nil
}

// readName читает имя со сжатием, начиная с off. Возвращает имя и смещение
// сразу за ним в исходном месте.
func readName(msg []byte, off int) (string, int, error) {
	var labels []string
	next := -1
	for hops := 0; hops < 32; hops++ {
		if off >= len(msg) {
			return "", 0, errShort
		}
		l := int(msg[off])
		switch {
		case l == 0:
			if next < 0 {
				next = off + 1
			}
			return strings.ToLower(strings.Join(labels, ".")), next, nil
		case l&0xc0 == 0xc0:
			if off+1 >= len(msg) {
				return "", 0, errShort
			}
			if next < 0 {
				next = off + 2
			}
			off = int(binary.BigEndian.Uint16(msg[off:off+2]) & 0x3fff)
		default:
			if off+1+l > len(msg) {
				return "", 0, errShort
			}
			labels = append(labels, string(msg[off+1:off+1+l]))
			off += 1 + l
		}
	}
	return "", 0, errors.New("петля сжатия")
}

// IsTarget — googlevideo или rr-кэш в c.youtube.com.
func IsTarget(name string) bool {
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	if name == Suffix || strings.HasSuffix(name, "."+Suffix) {
		return true
	}
	// c.youtube.com may reach the queue by suffix; only rr cache names act.
	_, _, ok := ParseCluster(name)
	return ok
}

// Answer — что нашлось в ответе.
type Answer struct {
	Name  string       // имя из вопроса
	Addrs []netip.Addr // адреса A и AAAA из раздела ответов
}

// ParseReply разбирает IP-пакет с ответом DNS. Возвращает ok=false, если это
// не ответ про googlevideo или в нём нет адресов.
func ParseReply(pkt []byte) (Answer, bool) {
	msg, err := udpPayload(pkt)
	if err != nil {
		return Answer{}, false
	}
	return parseDNS(msg)
}

func parseDNS(msg []byte) (Answer, bool) {
	if len(msg) < 12 {
		return Answer{}, false
	}
	flags := binary.BigEndian.Uint16(msg[2:4])
	if flags&0x8000 == 0 { // не ответ
		return Answer{}, false
	}
	qd := int(binary.BigEndian.Uint16(msg[4:6]))
	an := int(binary.BigEndian.Uint16(msg[6:8]))
	if qd != 1 {
		return Answer{}, false
	}
	name, off, err := readName(msg, 12)
	if err != nil || off+4 > len(msg) {
		return Answer{}, false
	}
	if !IsTarget(name) {
		return Answer{}, false
	}
	off += 4
	a := Answer{Name: name}
	for i := 0; i < an; i++ {
		_, o, err := readName(msg, off)
		if err != nil || o+10 > len(msg) {
			break
		}
		typ := binary.BigEndian.Uint16(msg[o : o+2])
		rdlen := int(binary.BigEndian.Uint16(msg[o+8 : o+10]))
		rd := o + 10
		if rd+rdlen > len(msg) {
			break
		}
		switch {
		case typ == 1 && rdlen == 4:
			a.Addrs = append(a.Addrs, netip.AddrFrom4([4]byte(msg[rd:rd+4])))
		case typ == 28 && rdlen == 16:
			a.Addrs = append(a.Addrs, netip.AddrFrom16([16]byte(msg[rd:rd+16])))
		}
		off = rd + rdlen
	}
	return a, len(a.Addrs) > 0
}
