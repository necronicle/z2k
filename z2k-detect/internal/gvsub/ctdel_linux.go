//go:build linux

package gvsub

// Удаление записи conntrack через ctnetlink (утилиты conntrack на Keenetic
// нет). Нужно для соединений, открытых к плохому адресу до подмены: TCP
// открыт, ответа на TLS нет, и браузер ждёт на нём минутами — новые запросы
// к той же машине идут в это же соединение (10.11.2026, шортс крутился).
// Без записи следующий пакет клиента создаёт новую (tcp_loose), её
// переадресует подмена, рабочий сервер отвечает RST, и браузер сразу
// переподключается — уже через подмену.

import (
	"encoding/binary"
	"fmt"
	"sync/atomic"

	"golang.org/x/sys/unix"
)

const (
	nfnlSubsysCtnetlink = 1
	ipctnlMsgCtDelete   = 2

	ctaTupleOrig  = 1
	ctaTupleIP    = 1
	ctaTupleProto = 2
	ctaIPv4Src    = 1
	ctaIPv4Dst    = 2
	ctaIPv6Src    = 3
	ctaIPv6Dst    = 4
	ctaProtoNum   = 1
	ctaProtoSrc   = 2
	ctaProtoDst   = 3

	nlaFNested = 0x8000
)

var ctSeq atomic.Uint32

// ctDeleteMsg — сообщение удаления записи по исходному направлению.
func ctDeleteMsg(f Flow, seq uint32) ([]byte, error) {
	if !f.Src.IsValid() || !f.Dst.IsValid() || f.Src.Is4() != f.Dst.Is4() {
		return nil, fmt.Errorf("адреса записи: %v → %v", f.Src, f.Dst)
	}
	var proto byte = unix.IPPROTO_TCP
	if f.Proto == "udp" {
		proto = unix.IPPROTO_UDP
	}
	var ip []byte
	family := byte(unix.AF_INET)
	if f.Src.Is4() {
		s, d := f.Src.As4(), f.Dst.As4()
		ip = append(attr(ctaIPv4Src, s[:]), attr(ctaIPv4Dst, d[:])...)
	} else {
		family = unix.AF_INET6
		s, d := f.Src.As16(), f.Dst.As16()
		ip = append(attr(ctaIPv6Src, s[:]), attr(ctaIPv6Dst, d[:])...)
	}
	sp, dp := make([]byte, 2), make([]byte, 2)
	binary.BigEndian.PutUint16(sp, f.Sport)
	binary.BigEndian.PutUint16(dp, f.Dport)
	pr := append(attr(ctaProtoNum, []byte{proto}), attr(ctaProtoSrc, sp)...)
	pr = append(pr, attr(ctaProtoDst, dp)...)
	tuple := append(attr(ctaTupleIP|nlaFNested, ip), attr(ctaTupleProto|nlaFNested, pr)...)
	attrs := attr(ctaTupleOrig|nlaFNested, tuple)

	l := unix.SizeofNlMsghdr + 4 + len(attrs)
	b := make([]byte, l)
	binary.LittleEndian.PutUint32(b[0:4], uint32(l))
	binary.LittleEndian.PutUint16(b[4:6], nfnlSubsysCtnetlink<<8|ipctnlMsgCtDelete)
	binary.LittleEndian.PutUint16(b[6:8], unix.NLM_F_REQUEST|unix.NLM_F_ACK)
	binary.LittleEndian.PutUint32(b[8:12], seq)
	b[16] = family
	copy(b[20:], attrs)
	return b, nil
}

// DeleteFlow удаляет запись conntrack соединения.
func DeleteFlow(f Flow) error {
	seq := ctSeq.Add(1)
	msg, err := ctDeleteMsg(f, seq)
	if err != nil {
		return err
	}
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_NETFILTER)
	if err != nil {
		return fmt.Errorf("netlink: %w", err)
	}
	defer unix.Close(fd)
	if err := unix.Bind(fd, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return fmt.Errorf("netlink bind: %w", err)
	}
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &unix.Timeval{Sec: 1})
	if err := unix.Sendto(fd, msg, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return err
	}
	buf := make([]byte, 4096)
	n, _, err := unix.Recvfrom(fd, buf, 0)
	if err != nil {
		return err
	}
	if n >= 20 && binary.LittleEndian.Uint16(buf[4:6]) == unix.NLMSG_ERROR {
		if code := int32(binary.LittleEndian.Uint32(buf[16:20])); code != 0 {
			return unix.Errno(-code)
		}
	}
	return nil
}
