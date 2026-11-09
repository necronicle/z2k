//go:build linux

package gvsub

// Минимальный клиент NFQUEUE поверх сырого netlink: привязаться к очереди,
// получать пакеты целиком и отдавать вердикты в любом порядке. Своя реализация
// вместо сторонней библиотеки: нужно пять сообщений, а лишняя зависимость в
// бинарнике, который ездит на MIPS-роутеры, стоит дороже этих строк.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

const (
	nfnlSubsysQueue = 3

	nfqnlMsgPacket  = 0
	nfqnlMsgVerdict = 1
	nfqnlMsgConfig  = 2

	nfqaCfgCmd    = 1
	nfqaCfgParams = 2
	nfqaCfgMaxLen = 3
	nfqaCfgMask   = 4
	nfqaCfgFlags  = 5

	nfqnlCfgCmdBind = 1

	nfqnlCopyPacket  = 2
	nfqaCfgFFailOpen = 1

	nfqaPacketHdr  = 1
	nfqaVerdictHdr = 2
	nfqaPayload    = 10

	nfAccept = 1
)

// Queue — привязанная очередь.
type Queue struct {
	fd  int
	num uint16
	mu  sync.Mutex // запись вердиктов из разных горутин
	seq uint32
}

// Packet — пакет из очереди.
type Packet struct {
	ID      uint32
	Payload []byte
}

// OpenQueue привязывается к очереди num. Флаг fail-open: если служба не
// успевает разбирать, ядро пропускает пакеты, а не роняет их.
func OpenQueue(num uint16) (*Queue, error) {
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_NETFILTER)
	if err != nil {
		return nil, fmt.Errorf("netlink: %w", err)
	}
	if err := unix.Bind(fd, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("netlink bind: %w", err)
	}
	_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, 1<<20)
	// Чтение с таймаутом: закрытие сокета из другой горутины не будит
	// заблокированный recvfrom, и служба не могла выйти по SIGTERM, пока не
	// придёт следующий пакет (стенд 09.11).
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &unix.Timeval{Usec: 500000})
	q := &Queue{fd: fd, num: num}

	cmd := []byte{nfqnlCfgCmdBind, 0, 0, 0}
	if err := q.config(attr(nfqaCfgCmd, cmd)); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("привязка к очереди %d: %w", num, err)
	}
	params := make([]byte, 5)
	binary.BigEndian.PutUint32(params[0:4], 0xffff)
	params[4] = nfqnlCopyPacket
	if err := q.config(attr(nfqaCfgParams, params)); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("режим копирования: %w", err)
	}
	maxlen := make([]byte, 4)
	binary.BigEndian.PutUint32(maxlen, 256)
	_ = q.config(attr(nfqaCfgMaxLen, maxlen))
	flags := make([]byte, 4)
	binary.BigEndian.PutUint32(flags, nfqaCfgFFailOpen)
	_ = q.config(append(attr(nfqaCfgFlags, flags), attr(nfqaCfgMask, flags)...))
	return q, nil
}

func attr(typ uint16, data []byte) []byte {
	l := 4 + len(data)
	b := make([]byte, (l+3)&^3)
	binary.LittleEndian.PutUint16(b[0:2], uint16(l))
	binary.LittleEndian.PutUint16(b[2:4], typ)
	copy(b[4:], data)
	return b
}

func (q *Queue) message(msgType uint16, flags uint16, attrs []byte) []byte {
	q.seq++
	l := unix.SizeofNlMsghdr + 4 + len(attrs)
	b := make([]byte, l)
	binary.LittleEndian.PutUint32(b[0:4], uint32(l))
	binary.LittleEndian.PutUint16(b[4:6], nfnlSubsysQueue<<8|msgType)
	binary.LittleEndian.PutUint16(b[6:8], unix.NLM_F_REQUEST|flags)
	binary.LittleEndian.PutUint32(b[8:12], q.seq)
	// nfgenmsg: семейство, версия, номер очереди (big endian)
	b[16] = unix.AF_UNSPEC
	b[17] = 0
	binary.BigEndian.PutUint16(b[18:20], q.num)
	copy(b[20:], attrs)
	return b
}

// config шлёт настройку и ждёт подтверждения ядра.
func (q *Queue) config(attrs []byte) error {
	q.mu.Lock()
	msg := q.message(nfqnlMsgConfig, unix.NLM_F_ACK, attrs)
	seq := q.seq
	q.mu.Unlock()
	if err := unix.Sendto(q.fd, msg, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return err
	}
	buf := make([]byte, 8192)
	for {
		n, _, err := unix.Recvfrom(q.fd, buf, 0)
		if err != nil {
			return err
		}
		msgs, err := syscall.ParseNetlinkMessage(buf[:n])
		if err != nil {
			return err
		}
		for _, m := range msgs {
			if m.Header.Seq != seq || m.Header.Type != unix.NLMSG_ERROR {
				continue
			}
			if len(m.Data) < 4 {
				return errors.New("короткий ответ netlink")
			}
			if code := int32(binary.LittleEndian.Uint32(m.Data[0:4])); code != 0 {
				return unix.Errno(-code)
			}
			return nil
		}
	}
}

// Read блокируется до следующей пачки пакетов.
func (q *Queue) Read(buf []byte) ([]Packet, error) {
	n, _, err := unix.Recvfrom(q.fd, buf, 0)
	if err != nil {
		if errors.Is(err, unix.ENOBUFS) || errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EINTR) {
			return nil, nil // переполнение приёма (fail-open пропустил пакеты) или таймаут чтения
		}
		return nil, err
	}
	return splitPackets(buf[:n]), nil
}

// splitPackets режет пачку сообщений netlink сам, а не через
// syscall.ParseNetlinkMessage: тот требует, чтобы в буфере помещалась
// ВЫРОВНЕННАЯ длина каждого сообщения, а ядро не дополняет последнее
// сообщение о пакете до кратного 4 — на роутере 09.11 это давало EINVAL на
// первом же ответе DNS нечётной длины.
func splitPackets(b []byte) []Packet {
	var out []Packet
	for len(b) >= unix.SizeofNlMsghdr {
		l := int(binary.LittleEndian.Uint32(b[0:4]))
		typ := binary.LittleEndian.Uint16(b[4:6])
		if l < unix.SizeofNlMsghdr || l > len(b) {
			break
		}
		data := b[unix.SizeofNlMsghdr:l]
		if typ == nfnlSubsysQueue<<8|nfqnlMsgPacket && len(data) >= 4 {
			if p, ok := parsePacketAttrs(data[4:]); ok {
				out = append(out, p)
			}
		}
		al := (l + 3) &^ 3
		if al >= len(b) {
			break
		}
		b = b[al:]
	}
	return out
}

func parsePacketAttrs(b []byte) (Packet, bool) {
	var p Packet
	have := false
	for len(b) >= 4 {
		l := int(binary.LittleEndian.Uint16(b[0:2]))
		typ := binary.LittleEndian.Uint16(b[2:4]) & 0x3fff
		if l < 4 || l > len(b) {
			break
		}
		data := b[4:l]
		switch typ {
		case nfqaPacketHdr:
			if len(data) >= 4 {
				p.ID = binary.BigEndian.Uint32(data[0:4])
				have = true
			}
		case nfqaPayload:
			p.Payload = append([]byte(nil), data...)
		}
		al := (l + 3) &^ 3
		if al > len(b) {
			break
		}
		b = b[al:]
	}
	return p, have
}

// Accept пропускает пакет без изменений.
func (q *Queue) Accept(id uint32) error {
	v := make([]byte, 8)
	binary.BigEndian.PutUint32(v[0:4], nfAccept)
	binary.BigEndian.PutUint32(v[4:8], id)
	q.mu.Lock()
	msg := q.message(nfqnlMsgVerdict, 0, attr(nfqaVerdictHdr, v))
	q.mu.Unlock()
	return unix.Sendto(q.fd, msg, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK})
}

// Close закрывает сокет; ядро отвязывает очередь само.
func (q *Queue) Close() error { return unix.Close(q.fd) }
