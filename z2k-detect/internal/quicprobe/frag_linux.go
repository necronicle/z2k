//go:build linux

package quicprobe

import (
	"context"
	"errors"
	"fmt"
	"net"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// ФРАГМЕНТИРОВАННАЯ ОТПРАВКА.
//
// Зачем сырой сокет. Всё остальное в этом пакете обходится обычным: у UDP нет
// номеров последовательности, которые надо подделывать, а фальшивка — просто
// вторая датаграмма в тот же сокет. Фрагментация — единственное исключение:
// ядро само режет только по MTU, а нам нужен разрез в заданной позиции, с
// заданным перекрытием и в заданном порядке.
//
// Порядок проверки задан не нами, а физикой: СНАЧАЛА выясняется, доживают ли
// фрагменты до сервера ВООБЩЕ. Если на канале их режет CGNAT или коробка
// провайдера, «не помогло» будет означать «приём убивает трафик», а не
// «коробка собирает» — и рекомендовать такое плечо человеку значит тихо
// сломать ему сеть. Поэтому выживаемость меряется на нейтральном имени, и
// только при её подтверждении задаются вопросы по существу.
func exchangeFragmented(ctx context.Context, addr *net.UDPAddr, spec probeSpec,
	timeout time.Duration) exchangeResult {

	// Обычный сокет нужен, чтобы (а) получить исходный порт и адрес, (б)
	// принять ответ: ядро отдаст его тому, кто занял пятёрку.
	d := net.Dialer{Control: markControl}
	if spec.srcPort > 0 {
		d.LocalAddr = &net.UDPAddr{Port: spec.srcPort}
	}
	c, err := d.DialContext(ctx, "udp4", addr.String())
	if err != nil {
		return exchangeResult{err: err}
	}
	defer c.Close()
	conn, ok := c.(*net.UDPConn)
	if !ok {
		return exchangeResult{err: errors.New("quicprobe: сокет не UDP")}
	}
	local, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return exchangeResult{err: errors.New("quicprobe: нет локального адреса")}
	}
	src4, dst4 := local.IP.To4(), addr.IP.To4()
	if src4 == nil || dst4 == nil {
		return exchangeResult{err: errors.New("quicprobe: фрагментация только для IPv4")}
	}

	raw, err := unix.Socket(unix.AF_INET, unix.SOCK_RAW, unix.IPPROTO_RAW)
	if err != nil {
		return exchangeResult{err: fmt.Errorf("сырой сокет: %w", err)}
	}
	defer unix.Close(raw)
	// Без метки зонд уедет в нашу же очередь NFQUEUE и померит наш обход.
	// Прав может не быть — тогда идём без метки, как и обычный путь.
	if e := unix.SetsockoptInt(raw, unix.SOL_SOCKET, unix.SO_MARK, Z2KBypassMark); e != nil &&
		!errors.Is(e, unix.EPERM) && !errors.Is(e, unix.ENOPROTOOPT) {
		return exchangeResult{err: e}
	}

	to := &unix.SockaddrInet4{Port: addr.Port}
	copy(to.Addr[:], dst4)

	start := time.Now()
	for _, payload := range spec.pkts {
		frags, ferr := buildFragments(src4, dst4, uint16(local.Port), uint16(addr.Port),
			payload, *spec.frag, nextIPID())
		if ferr != nil {
			return exchangeResult{err: ferr}
		}
		for _, f := range frags {
			if e := unix.Sendto(raw, f, 0, to); e != nil {
				return exchangeResult{refused: errors.Is(e, syscall.ECONNREFUSED), err: e}
			}
		}
	}

	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	buf := make([]byte, 2048)
	for {
		n, rerr := conn.Read(buf)
		if rerr != nil {
			return exchangeResult{refused: errors.Is(rerr, syscall.ECONNREFUSED)}
		}
		resp, perr := Parse(buf[:n], spec.dcid, spec.ver)
		if perr == nil && resp.Answered() {
			return exchangeResult{ms: time.Since(start).Milliseconds(), ok: true}
		}
		if time.Since(start) > timeout {
			return exchangeResult{}
		}
	}
}
