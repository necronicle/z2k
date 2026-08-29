//go:build linux

// Сырой слой зондов: то, что нельзя сделать обычным сокетом.
//
// ЗАЧЕМ ЦЕЛИКОМ СВОЙ TCP, А НЕ ЯДЕРНЫЙ СОКЕТ ПЛЮС ИНЪЕКЦИЯ. Чтобы отравить
// буфер пересборки, фальшивый сегмент обязан лечь в ТУ ЖЕ область
// последовательности, что и настоящие данные. Значит нужно знать snd_nxt
// соединения — а ядро его наружу не отдаёт: в struct tcp_info такого поля нет.
// Подсмотреть можно только сниффером, но к тому моменту настоящий сегмент уже
// ушёл, и травить поздно.
//
// Поэтому рукопожатие делается здесь: SYN, SYN-ACK, ACK. Нам не нужен полный
// стек — ни ретрансмиты, ни окно, ни контроль перегрузки. Нужно несколько
// пакетов с полным контролем над каждым полем, а живёт соединение секунды.
//
// ЯДРО ПРИДЁТСЯ ПРИДЕРЖАТЬ. О нашем соединении оно не знает и на SYN-ACK
// ответит своим RST, оборвав зонд раньше, чем тот что-то измерит. На время
// работы ставим правило, роняющее исходящие RST с нашего порта, и снимаем его
// в defer. Порт случайный из эфемерного диапазона, правило узкое.
package classify

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"os/exec"
	"syscall"
	"time"
)

// rawSupported сообщает, доступен ли сырой слой на этой сборке.
func rawSupported() bool { return true }

type rawConn struct {
	sendFD   int
	recvFD   int
	src      net.IP
	dst      net.IP
	sport    uint16
	dport    uint16
	seq      uint32 // наш следующий номер
	ack      uint32 // что подтверждаем
	wantOpts bool   // класть ли в SYN обычный набор опций
	cleanup  func()
}

// dialRaw поднимает соединение своими руками и возвращает его установленным.
func dialRaw(ctx context.Context, dstIP net.IP, dport uint16, timeout time.Duration) (*rawConn, error) {
	dst4 := dstIP.To4()
	if dst4 == nil {
		return nil, errors.New("classify: сырой слой пока только IPv4")
	}
	src, err := localAddrFor(dst4, dport)
	if err != nil {
		return nil, err
	}
	sfd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
	if err != nil {
		return nil, fmt.Errorf("classify: сырой сокет на отправку (нужен root): %w", err)
	}
	// МЕТКА, ОТКЛЮЧАЮЩАЯ НАШ ЖЕ ОБХОД.
	//
	// Замер обязан идти по СЫРОМУ пути, иначе меряется не коробка провайдера,
	// а наш десинк поверх неё. Раньше для этого приходилось лезть в ipset
	// nozapret живого роутера на каждый хост — приём рабочий, но на сорока
	// хостах это сорок правок боевого набора, и один оборванный прогон
	// оставляет чужой адрес без обхода (поле 2026-08-29, так и вышло).
	//
	// В правилах NFQUEUE уже есть дверь: `-m mark ! --mark 0x40000000`.
	// Ставим эту метку на свои пакеты и выходим мимо очереди, ничего в
	// системе не трогая.
	_ = syscall.SetsockoptInt(sfd, syscall.SOL_SOCKET, syscall.SO_MARK, Z2KBypassMark)
	if err := syscall.SetsockoptInt(sfd, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		syscall.Close(sfd)
		return nil, err
	}
	rfd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		syscall.Close(sfd)
		return nil, err
	}
	tv := syscall.NsecToTimeval(int64(300 * time.Millisecond))
	_ = syscall.SetsockoptTimeval(rfd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)

	c := &rawConn{sendFD: sfd, recvFD: rfd, src: src, dst: dst4, dport: dport}
	c.wantOpts = true
	c.sport = uint16(30000 + rand.Intn(25000))
	c.seq = rand.Uint32()
	c.cleanup = suppressKernelRST(c.sport)

	if err := c.handshake(ctx, timeout); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

func (c *rawConn) Close() {
	if c.cleanup != nil {
		c.cleanup()
	}
	if c.sendFD > 0 {
		syscall.Close(c.sendFD)
	}
	if c.recvFD > 0 {
		syscall.Close(c.recvFD)
	}
}

// suppressKernelRST закрывает ядру рот на время зонда и возвращает уборщика.
func suppressKernelRST(sport uint16) func() {
	args := []string{"-I", "OUTPUT", "-p", "tcp", "--sport", fmt.Sprint(sport),
		"--tcp-flags", "RST", "RST", "-j", "DROP"}
	if err := exec.Command("iptables", args...).Run(); err != nil {
		// Без правила зонд обычно всё равно успевает отработать: ядерный RST
		// прилетает после SYN-ACK, а мы к тому моменту уже пишем данные.
		// Молчим намеренно — отказ здесь не повод не мерить.
		return func() {}
	}
	return func() {
		del := append([]string{"-D", "OUTPUT"}, args[2:]...)
		_ = exec.Command("iptables", del...).Run()
	}
}

// localAddrFor узнаёт, с какого адреса ядро пошло бы к этой цели.
func localAddrFor(dst net.IP, port uint16) (net.IP, error) {
	c, err := net.Dial("udp", net.JoinHostPort(dst.String(), fmt.Sprint(port)))
	if err != nil {
		return nil, err
	}
	defer c.Close()
	ua, ok := c.LocalAddr().(*net.UDPAddr)
	if !ok {
		return nil, errors.New("classify: не удалось определить свой адрес")
	}
	ip := ua.IP.To4()
	if ip == nil {
		return nil, errors.New("classify: свой адрес не IPv4")
	}
	return ip, nil
}

func (c *rawConn) handshake(ctx context.Context, timeout time.Duration) error {
	// SYN С ОПЦИЯМИ. Голое приветствие без MSS, SACK, меток времени и масштаба
	// окна — само по себе аномалия: так не здоровается ни один настоящий
	// клиент, и коробка вправе относиться к такому потоку иначе. Замер должен
	// выглядеть как обычный трафик, иначе он мерит реакцию на себя.
	if err := c.sendSYN(); err != nil {
		return err
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		flags, seq, ack, _, err := c.recv()
		if err != nil {
			continue
		}
		if flags&tcpRST != 0 {
			return errors.New("classify: сервер ответил RST на SYN")
		}
		if flags&tcpSYN != 0 && flags&tcpACK != 0 {
			if ack != c.seq+1 {
				continue
			}
			c.seq++
			c.ack = seq + 1
			return c.send(nil, tcpACK, poison{})
		}
	}
	return errors.New("classify: SYN-ACK не пришёл")
}

// sendSYN шлёт SYN с обычным набором опций: MSS, SACK-permitted, метки
// времени, масштаб окна — ровно то, что кладёт ядро.
func (c *rawConn) sendSYN() error {
	opts := []byte{
		2, 4, 0x05, 0xac, // MSS 1452
		4, 2, // SACK permitted
		8, 10, 0, 0, 0, 1, 0, 0, 0, 0, // timestamps
		1,       // NOP
		3, 3, 7, // window scale 7
	}
	pkt := buildIPv4TCPOpts(c.src, c.dst, c.sport, c.dport, c.seq, 0, tcpSYN, nil, poison{}, opts)
	var to syscall.SockaddrInet4
	copy(to.Addr[:], c.dst)
	to.Port = int(c.dport)
	return syscall.Sendto(c.sendFD, pkt, 0, &to)
}

const (
	tcpFIN = 0x01
	tcpSYN = 0x02
	tcpRST = 0x04
	tcpPSH = 0x08
	tcpACK = 0x10
)

// send кладёт один сегмент на провод. Номер последовательности НЕ двигается
// при отравленной посылке: фальшивка обязана занять ту же область, что займут
// настоящие данные, иначе травить нечего.
func (c *rawConn) send(payload []byte, flags uint8, p poison) error {
	seq := c.seq
	if p.seqShift != 0 {
		seq = uint32(int64(seq) + int64(p.seqShift))
	}
	pkt := buildIPv4TCP(c.src, c.dst, c.sport, c.dport, seq, c.ack, flags, payload, p)
	var to syscall.SockaddrInet4
	copy(to.Addr[:], c.dst)
	to.Port = int(c.dport)
	return syscall.Sendto(c.sendFD, pkt, 0, &to)
}

// recv возвращает следующий сегмент ОТ НАШЕГО пира.
func (c *rawConn) recv() (flags uint8, seq, ack uint32, payload []byte, err error) {
	buf := make([]byte, 65535)
	for {
		n, _, e := syscall.Recvfrom(c.recvFD, buf, 0)
		if e != nil {
			return 0, 0, 0, nil, e
		}
		if n < 40 {
			continue
		}
		ihl := int(buf[0]&0x0f) * 4
		if n < ihl+20 {
			continue
		}
		if !net.IP(buf[12:16]).Equal(c.dst) {
			continue
		}
		t := buf[ihl:n]
		sp := binary.BigEndian.Uint16(t[0:2])
		dp := binary.BigEndian.Uint16(t[2:4])
		if sp != c.dport || dp != c.sport {
			continue
		}
		off := int(t[12]>>4) * 4
		if off > len(t) {
			continue
		}
		return t[13], binary.BigEndian.Uint32(t[4:8]), binary.BigEndian.Uint32(t[8:12]), t[off:], nil
	}
}

// readPayload ждёт от сервера сегмент с данными.
func (c *rawConn) readPayload(ctx context.Context, timeout time.Duration) ([]byte, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		flags, _, _, pay, err := c.recv()
		if err != nil {
			continue
		}
		if flags&tcpRST != 0 {
			return nil, errors.New("RST")
		}
		if len(pay) > 0 {
			return pay, nil
		}
	}
	return nil, errors.New("тишина")
}

// buildIPv4TCP собирает пакет целиком. Контрольные суммы считаем сами: ядро
// их для IP_HDRINCL не трогает, а нам порча суммы нужна как инструмент.
func buildIPv4TCP(src, dst net.IP, sport, dport uint16, seq, ack uint32, flags uint8, payload []byte, p poison) []byte {
	return buildIPv4TCPOpts(src, dst, sport, dport, seq, ack, flags, payload, p, nil)
}

func buildIPv4TCPOpts(src, dst net.IP, sport, dport uint16, seq, ack uint32, flags uint8, payload []byte, p poison, extra []byte) []byte {
	opts := extra
	if p.tcpTS {
		// Метка времени со сдвигом назад: сервер бракует устаревшую, коробка
		// её не сверяет. Значение произвольное, важен сам факт «в прошлом».
		ts := make([]byte, 12)
		ts[0], ts[1] = 1, 1 // NOP, NOP — выравнивание
		ts[2], ts[3] = 8, 10
		binary.BigEndian.PutUint32(ts[4:8], 1)
		opts = append(opts, ts...)
	}
	if p.md5 {
		// TCP-MD5 (kind 19, len 18) плюс NOP-ы до кратности четырём.
		opts = make([]byte, 20)
		opts[0] = 19
		opts[1] = 18
		opts[18], opts[19] = 1, 1
	}
	for len(opts)%4 != 0 {
		opts = append(opts, 0)
	}
	dataOff := 5 + len(opts)/4
	tcpLen := dataOff*4 + len(payload)
	ipLen := 20 + tcpLen

	pkt := make([]byte, ipLen)
	pkt[0] = 0x45
	binary.BigEndian.PutUint16(pkt[2:4], uint16(ipLen))
	if !p.ipIDZero {
		binary.BigEndian.PutUint16(pkt[4:6], uint16(rand.Intn(65535)))
	}
	ttl := byte(64)
	if p.ttl > 0 {
		ttl = byte(p.ttl)
	}
	pkt[8] = ttl
	pkt[9] = syscall.IPPROTO_TCP
	copy(pkt[12:16], src.To4())
	copy(pkt[16:20], dst.To4())
	binary.BigEndian.PutUint16(pkt[10:12], checksum(pkt[:20]))

	t := pkt[20:]
	binary.BigEndian.PutUint16(t[0:2], sport)
	binary.BigEndian.PutUint16(t[2:4], dport)
	binary.BigEndian.PutUint32(t[4:8], seq)
	binary.BigEndian.PutUint32(t[8:12], ack)
	t[12] = byte(dataOff << 4)
	t[13] = flags
	binary.BigEndian.PutUint16(t[14:16], 65535)
	copy(t[20:], opts)
	copy(t[dataOff*4:], payload)

	sum := tcpChecksum(src, dst, t)
	if p.badsum {
		sum ^= 0xbeef
		if sum == 0 {
			sum = 0x1234
		}
	}
	binary.BigEndian.PutUint16(t[16:18], sum)
	return pkt
}

func tcpChecksum(src, dst net.IP, t []byte) uint16 {
	ph := make([]byte, 12+len(t))
	copy(ph[0:4], src.To4())
	copy(ph[4:8], dst.To4())
	ph[9] = syscall.IPPROTO_TCP
	binary.BigEndian.PutUint16(ph[10:12], uint16(len(t)))
	copy(ph[12:], t)
	ph[12+16], ph[12+17] = 0, 0
	return checksum(ph)
}

func checksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(b[i : i+2]))
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

// probeRawHandshake — самопроверка сырого слоя: доходит ли наше собственное
// рукопожатие. Проверять его отправкой полезной нагрузки нельзя — поле
// 2026-08-28, googlevideo: тот фронтенд обслуживает только заблокированные
// имена, безобидной нагрузки для него не существует, и самопроверка падала не
// потому, что слой сломан, а потому, что отвечать было не на что. И падение
// это глушило весь перебор.
//
// Рукопожатие свободно от этой беды: SYN-ACK приходит от TCP-стека сервера ещё
// до того, как он узнает, чего мы хотим. Прошло — значит наши контрольные
// суммы верны, ядро придержано и сокеты живые. Ровно это и требовалось знать.
func probeRawHandshake(ctx context.Context, dstIP net.IP, port uint16, timeout time.Duration) (bool, error) {
	c, err := dialRaw(ctx, dstIP, port, timeout)
	if err != nil {
		return false, err
	}
	c.Close()
	return true, nil
}

// probePoison — ОДИН зонд, собранный из независимых приёмов.
//
// Почему сборкой, а не набором готовых случаев. Боевое плечо для googlevideo
// это фальшивка С БИТОЙ СУММОЙ И НИЗКИМ TTL плюс настоящие сегменты, пущенные
// НЕ ПО ПОРЯДКУ, — всё сразу, в одной стратегии. Зонды, проверяющие приёмы по
// одному, такую коробку не поймают никогда, и каждый из них провалится
// «правильно»: замер 2026-08-28 — 48 гипотез поодиночке мимо, а то же плечо в
// связке даёт 10 из 10 на том же адресе.
//
// Поэтому здесь два независимых шага, которые комбинируются свободно:
//  1. отравить буфер фальшивкой (сумма, TTL, MD5, номер вне окна);
//  2. отдать правду — как есть, задом наперёд или внахлёст слева.
func probePoison(ctx context.Context, dstIP net.IP, port uint16, tr Trigger, p poison, timeout time.Duration) (bool, error) {
	c, err := dialRaw(ctx, dstIP, port, timeout)
	if err != nil {
		return false, err
	}
	defer c.Close()

	// ШАГ 1: фальшивка в ту же область последовательности, что займёт правда.
	// Перекрытие слева её не использует: там приманка едет внутри самого
	// сегмента с данными, отдельной посылки не нужно.
	// ФАЛЬШИВКА — ОТДЕЛЬНАЯ ПОСЫЛКА, А НЕ НАЧИНКА ПЕРЕКРЫТИЯ.
	//
	// Раньше эти два приёма были взаимоисключающими: при перекрытии фальшивка
	// не слалась вовсе, а приманка клалась ВНУТРЬ перекрывающего сегмента.
	// Дамп боевого плеча 2026-08-29 показал, что это разные вещи и идут они
	// подряд:
	//     ttl 63  seq 1:678     len 677   × 7   ← фальшивка, семь копий
	//     ttl 64  seq -680:2    len 682         ← перекрытие слева
	//     ttl 64  seq 2:1210    len 1208        ← остальное приветствие
	// Семёрка здесь та же, что вымерена на googlevideo, и это не совпадение:
	// механизм у коробки один.
	if p.name != "none" && p.hasFake() {
		// ФАЛЬШИВКА ДЛИННЕЕ ПРАВДЫ, и это тоже из дампа: боевое плечо шлёт 677
		// байт на приветствие в 343, то есть накрывает его целиком И заходит
		// за край. Коробка, дочитывающая запись до конца, на укороченной
		// фальшивке осталась бы ждать продолжения и приняла бы настоящие
		// байты как это продолжение — отравление тогда не срабатывает.
		fake := make([]byte, len(tr.Payload)*2)
		for i := range fake {
			fake[i] = 0x0f
		}
		if len(p.decoyPayload) > 0 {
			// Коробке, разбирающей протокол, набивка не годится: она её
			// пропустит мимо и продолжит ждать настоящее приветствие.
			copy(fake, p.decoyPayload)
		}
		reps := p.repeats
		if reps < 1 {
			reps = 1
		}
		for i := 0; i < reps; i++ {
			if err := c.send(fake, tcpPSH|tcpACK, p); err != nil {
				return false, err
			}
			if p.gapMS > 0 && i+1 < reps {
				time.Sleep(time.Duration(p.gapMS) * time.Millisecond)
			}
		}
		time.Sleep(15 * time.Millisecond)
	}

	// ШАГ 2: настоящие данные.
	base := c.seq
	switch {
	case p.seqovl > 0 && p.disorder:
		// ПЕРЕКРЫТИЕ ВМЕСТЕ С ПОРЯДКОМ. Раньше это были взаимоисключающие
		// ветки, и связка не проверялась вовсе — а боевое плечо 1 пула
		// rkn_tcp именно такое: multisplit с seqovl И multidisorder на одном
		// соединении. Замер 2026-08-29: три хоста, которые арсенал берёт, а
		// мои семьдесят гипотез нет, стояли ровно на нём.
		n := len(tr.Payload)
		mid := n / 2
		if tr.SNILen > 1 && tr.SNIOffset > 0 {
			mid = tr.SNIOffset + tr.SNILen/2
		}
		if mid < 2 {
			mid = 2
		}
		if mid >= n {
			mid = n - 1
		}
		// Хвост уходит первым, голова — последней и внахлёст слева.
		c.seq = base + uint32(mid)
		if err := c.send(tr.Payload[mid:], tcpPSH|tcpACK, poison{}); err != nil {
			return false, err
		}
		time.Sleep(12 * time.Millisecond)
		c.seq = base + 1
		if err := c.send(tr.Payload[1:mid], tcpPSH|tcpACK, poison{}); err != nil {
			return false, err
		}
		time.Sleep(12 * time.Millisecond)
		junk := make([]byte, p.seqovl)
		for i := range junk {
			junk[i] = 0x0f
		}
		if len(p.decoyPayload) > 0 {
			copy(junk, p.decoyPayload)
		}
		c.seq = base - uint32(p.seqovl)
		if err := c.send(append(junk, tr.Payload[:1]...), tcpPSH|tcpACK, poison{}); err != nil {
			return false, err
		}
	case p.seqovl > 0:
		// Внахлёст слева: один сегмент с номером base-N, где первые N байт —
		// приманка. Сервер подрежет левый край окна и возьмёт правду.
		n := p.seqovl
		junk := make([]byte, n)
		for i := range junk {
			junk[i] = 0x0f
		}
		if len(p.decoyPayload) > 0 {
			copy(junk, p.decoyPayload)
		}
		c.seq = base - uint32(n)
		if err := c.send(append(junk, tr.Payload...), tcpPSH|tcpACK, poison{}); err != nil {
			return false, err
		}
	case p.disorder:
		// ТРИ КУСКА, ПЕРВЫЙ БАЙТ — ПОСЛЕДНИМ. Дамп боевого плеча:
		//   seq 268:344 (76 б), seq 2:268 (266 б), seq 1:2 (1 б)
		// То есть `multidisorder:pos=1,midsld` режет по единице и по середине
		// домена, а на провод кладёт задом наперёд, и одинокий первый байт
		// уходит в самом конце. Деление пополам на два куска, которое я делал
		// раньше, воспроизводит не это: коробке достаётся осмысленное начало
		// записи, и она спокойно дожидается остального.
		n := len(tr.Payload)
		// РЕЖЕМ ПО ИМЕНИ, А НЕ ПО СЕРЕДИНЕ ПАКЕТА. Коробка ищет имя хоста;
		// разорвано оно между сегментами или лежит в одном куске — это и есть
		// разница между «сработало» и «нет». Боевое плечо режет на `midsld`,
		// в середине домена второго уровня. Пополам — мимо: имя остаётся целым.
		mid := n / 2
		if tr.SNILen > 1 && tr.SNIOffset > 0 {
			mid = tr.SNIOffset + tr.SNILen/2
		}
		if mid < 2 {
			mid = 2
		}
		if mid >= n {
			mid = n - 1
		}
		type piece struct{ from, to int }
		order := []piece{{mid, n}, {1, mid}, {0, 1}}
		for _, pc := range order {
			c.seq = base + uint32(pc.from)
			if err := c.send(tr.Payload[pc.from:pc.to], tcpPSH|tcpACK, poison{}); err != nil {
				return false, err
			}
			time.Sleep(12 * time.Millisecond)
		}
	default:
		if err := c.send(tr.Payload, tcpPSH|tcpACK, poison{}); err != nil {
			return false, err
		}
	}
	c.seq = base + uint32(len(tr.Payload))

	pay, err := c.readPayload(ctx, timeout)
	if err != nil {
		return false, nil
	}
	if tr.Accept != nil && !tr.Accept(pay) {
		return false, nil
	}
	return true, nil
}
