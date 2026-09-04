package quicprobe

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"net"
	"sync/atomic"
)

// Сборка IP-фрагментов. Вынесена из платформенного файла намеренно: это чистая
// арифметика, она обязана совпадать с z2k_ipfrag3_params построчно, и
// проверяется тестом на любой машине, а не только там, где есть сырые сокеты.

const protoUDP = 17

// nextIPID выдаёт идентификатор для сборки фрагментов.
//
// ПОЧЕМУ СЧЁТЧИК, А НЕ ЕДИНИЦА. Ядро собирает фрагменты по ключу
// (адрес источника, адрес назначения, протокол, IP ID) — ПОРТЫ В КЛЮЧ НЕ
// ВХОДЯТ. Повторы зонда идут параллельно на один и тот же адрес, и с
// одинаковым идентификатором их фрагменты сливаются в одну сборку, портя друг
// друга. Поймано замером на живом Linux: одиночный прогон проходил, а три
// параллельных давали тишину — то есть ошибка выглядела бы ровно как
// блокировка.
//
// Начальное значение случайное: последовательные прогоны инструмента не должны
// попадать в чужие недособранные очереди, которые ядро держит ipfrag_time
// секунд (по умолчанию 30).
var ipIDCounter atomic.Uint32

func init() {
	var b [2]byte
	_, _ = rand.Read(b[:])
	ipIDCounter.Store(uint32(binary.BigEndian.Uint16(b[:])))
}

func nextIPID() uint16 {
	id := uint16(ipIDCounter.Add(1))
	if id == 0 {
		// Ноль означает «идентификатор не задан»: ядро на пути подставит свой,
		// и фрагменты одной датаграммы разъедутся по разным сборкам.
		id = uint16(ipIDCounter.Add(1)) | 1
	}
	return id
}

// buildFragments собирает IP-фрагменты одной UDP-датаграммы.
//
// Разрезы считаются от начала UDP-заголовка — так же, как ipfrag_pos_udp в
// движке, и поэтому боевое умолчание 8 отправляет в первом фрагменте ровно
// заголовок, а всё содержимое во втором.
func buildFragments(src, dst net.IP, sport, dport uint16, payload []byte,
	plan fragPlan, ipID uint16) ([][]byte, error) {

	l4 := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint16(l4[0:], sport)
	binary.BigEndian.PutUint16(l4[2:], dport)
	binary.BigEndian.PutUint16(l4[4:], uint16(8+len(payload)))
	copy(l4[8:], payload)
	binary.BigEndian.PutUint16(l4[6:], udpChecksum(src, dst, l4))

	total := len(l4)
	cuts, err := planCuts(total, plan)
	if err != nil {
		return nil, err
	}

	out := make([][]byte, 0, len(cuts))
	for i, c := range cuts {
		last := i == len(cuts)-1
		out = append(out, ipPacket(src, dst, ipID, c.off, l4[c.off:c.off+c.len], !last))
	}
	if plan.disorder {
		for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
			out[i], out[j] = out[j], out[i]
		}
	}
	return out, nil
}

type cut struct{ off, len int }

// planCuts повторяет арифметику z2k_ipfrag3_params построчно. Своей трактовки
// здесь нет намеренно: любое расхождение означало бы, что зонд меряет один
// разрез, а конфиг делает другой.
func planCuts(total int, p fragPlan) ([]cut, error) {
	align8 := func(v int) int { return v &^ 7 }

	pos1 := align8(p.pos1)
	if pos1 < 8 {
		pos1 = 8
	}
	if pos1 >= total {
		return nil, errors.New("quicprobe: датаграмма короче первого разреза")
	}
	if !p.three {
		return []cut{{0, pos1}, {pos1, total - pos1}}, nil
	}

	if total <= 24 {
		return nil, errors.New("quicprobe: датаграмма коротка для трёх фрагментов")
	}
	pos2 := p.pos2
	if pos2 == 0 {
		pos2 = pos1 + 24 // ipfrag_span по умолчанию
	}
	pos2 = align8(pos2)
	ov12, ov23 := align8(p.ov12), align8(p.ov23)
	if pos2 <= pos1 {
		pos2 = pos1 + 8
	}
	if pos2 >= total {
		pos2 = align8(total - 8)
	}
	if pos2 <= pos1 {
		return nil, errors.New("quicprobe: не раскладывается на три фрагмента")
	}
	if ov12 > pos1-8 {
		ov12 = pos1 - 8
	}
	if ov23 > pos2-8 {
		ov23 = pos2 - 8
	}
	off2, off3 := pos1-ov12, pos2-ov23
	if off2 < 0 {
		off2 = 0
	}
	if off3 <= off2 {
		off3 = off2 + 8
	}
	if off3 >= total {
		off3 = align8(total - 8)
	}
	if off3 <= off2 || off3 >= total {
		return nil, errors.New("quicprobe: не раскладывается на три фрагмента")
	}
	len1, len2, len3 := pos1, pos2-off2, total-off3
	if len1 <= 0 || len2 <= 0 || len3 <= 0 {
		return nil, errors.New("quicprobe: пустой фрагмент")
	}
	return []cut{{0, len1}, {off2, len2}, {off3, len3}}, nil
}

// ipPacket собирает один фрагмент вместе с заголовком IPv4.
//
// Идентификатор обязан быть НЕНУЛЕВЫМ: с нулём ядро на пути подставит свой, и
// фрагменты одной датаграммы разъедутся по разным сборкам — приём тихо
// перестанет работать, а выглядеть это будет как блокировка.
func ipPacket(src, dst net.IP, id uint16, offset int, data []byte, more bool) []byte {
	pkt := make([]byte, 20+len(data))
	pkt[0] = 0x45 // версия 4, заголовок 5 слов
	binary.BigEndian.PutUint16(pkt[2:], uint16(20+len(data)))
	binary.BigEndian.PutUint16(pkt[4:], id)
	flags := uint16(offset / 8)
	if more {
		flags |= 0x2000 // MF
	}
	binary.BigEndian.PutUint16(pkt[6:], flags)
	pkt[8] = 64 // TTL
	pkt[9] = protoUDP
	copy(pkt[12:16], src.To4())
	copy(pkt[16:20], dst.To4())
	binary.BigEndian.PutUint16(pkt[10:], checksum(pkt[:20]))
	copy(pkt[20:], data)
	return pkt
}

// udpChecksum считается по ЦЕЛОЙ датаграмме, до разрезания: приёмник считает
// её после сборки, и от фрагментации она не зависит.
func udpChecksum(src, dst net.IP, l4 []byte) uint16 {
	ph := make([]byte, 12+len(l4))
	copy(ph[0:4], src.To4())
	copy(ph[4:8], dst.To4())
	ph[9] = protoUDP
	binary.BigEndian.PutUint16(ph[10:], uint16(len(l4)))
	copy(ph[12:], l4)
	c := checksum(ph)
	if c == 0 {
		// Ноль в UDP означает «сумма не считана», а это другой смысл.
		c = 0xffff
	}
	return c
}

func checksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(b[i:]))
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}
