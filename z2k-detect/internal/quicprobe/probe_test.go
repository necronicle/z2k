package quicprobe

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"sync"
	"testing"
	"time"
)

// СТЕНД: эмулятор коробки на петле.
//
// Зачем он нужен именно здесь. Вся ценность замера в том, ЧТО он выводит из
// тишины, а тишину в поле не отличить от собственной ошибки: кривой Initial
// сервер выбросит так же молча, как его выбросила бы коробка. Значит логику
// вывода надо проверять там, где известна правда — то есть на своей же
// коробке с заранее заданным поведением.
//
// Эмулятор говорит на настоящем QUIC: он выводит ключи из DCID клиента ровно
// так же, как это делает коробка провайдера, расшифровывает Initial, достаёт
// имя и решает — ответить или промолчать. Ответ он собирает настоящий:
// серверный Initial с кадрами ACK и CRYPTO, зашифрованный серверными ключами.
// Поэтому зелёный тест здесь означает, что сошлись обе половины — и сборка
// пакета, и разбор ответа.

type fakeBox struct {
	t *testing.T
	// blocked — имя, которое коробка режет.
	blocked string
	// firstPacketOnly — разбирать только ПЕРВУЮ датаграмму потока. Так ведёт
	// себя GFW, и именно на этом стоит приём «мусор перед Initial».
	firstPacketOnly bool
	// residual — после срабатывания глушить всё с этого адреса.
	residual bool
	// answerInitial — отвечать ли на Initial вообще. Ложь изображает хост,
	// который не обслуживает HTTP/3.
	answerInitial bool
	// silent — не отвечать вообще ни на что, включая согласование версии.
	// Так выглядит блокировка по адресу: датаграммы исчезают молча, и ICMP
	// «порт недоступен» тоже не приходит, потому что до хоста они не доехали.
	silent bool

	conn *net.UDPConn

	mu       sync.Mutex
	seen     map[string]bool // пятёрка -> видели ли уже датаграмму
	tripped  bool
	requests int
}

func newFakeBox(t *testing.T, blocked string) *fakeBox {
	t.Helper()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("стенд не поднялся: %v", err)
	}
	b := &fakeBox{t: t, blocked: blocked, answerInitial: true, conn: c, seen: map[string]bool{}}
	go b.serve()
	t.Cleanup(func() { _ = c.Close() })
	return b
}

func (b *fakeBox) addr() string { return b.conn.LocalAddr().String() }

func (b *fakeBox) serve() {
	buf := make([]byte, 2048)
	for {
		n, from, err := b.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		pkt := append([]byte(nil), buf[:n]...)
		b.handle(pkt, from)
	}
}

func (b *fakeBox) handle(pkt []byte, from *net.UDPAddr) {
	b.mu.Lock()
	b.requests++
	if b.silent {
		b.mu.Unlock()
		return
	}
	if b.residual && b.tripped {
		b.mu.Unlock()
		return // след сработавшей блокировки: молчим на всё подряд
	}
	flow := from.String()
	firstInFlow := !b.seen[flow]
	b.seen[flow] = true
	b.mu.Unlock()

	// Согласование версии — ответ, не зависящий от содержимого.
	if len(pkt) >= 5 && pkt[0]&0x80 != 0 {
		if v := binary.BigEndian.Uint32(pkt[1:5]); v != uint32(V1) && v != uint32(V2) {
			b.sendVersionNegotiation(pkt, from)
			return
		}
	}

	dcid, sni, ok := b.inspect(pkt)
	if !ok {
		return // не Initial и не понятно что: настоящий сервер тоже промолчит
	}
	// Решение коробки. Разбирает она поток, только если Initial пришёл первым.
	inspectable := !b.firstPacketOnly || firstInFlow
	if inspectable && sni == b.blocked {
		b.mu.Lock()
		b.tripped = true
		b.mu.Unlock()
		return
	}
	if !b.answerInitial {
		return
	}
	b.sendServerInitial(dcid, from)
}

// inspect — то же, что делает коробка: вывести ключи из DCID и прочитать имя.
func (b *fakeBox) inspect(pkt []byte) (dcid []byte, sni string, ok bool) {
	if len(pkt) < 7 || pkt[0]&0x80 == 0 {
		return nil, "", false
	}
	ver := Version(binary.BigEndian.Uint32(pkt[1:5]))
	if ver != V1 && ver != V2 {
		return nil, "", false
	}
	if (pkt[0]&0x30)>>4 != initialType(ver) {
		return nil, "", false
	}
	off := 5
	dl := int(pkt[off])
	off++
	if off+dl > len(pkt) {
		return nil, "", false
	}
	dcid = pkt[off : off+dl]
	off += dl
	sl := int(pkt[off])
	off++
	off += sl
	if off >= len(pkt) {
		return nil, "", false
	}
	tl, n := readVarint(pkt[off:])
	if n == 0 {
		return nil, "", false
	}
	off += n + int(tl)
	length, n := readVarint(pkt[off:])
	if n == 0 {
		return nil, "", false
	}
	off += n
	pnOffset := off
	if pnOffset+int(length) > len(pkt) {
		return nil, "", false
	}
	client, _, err := deriveKeys(dcid, ver)
	if err != nil {
		return nil, "", false
	}
	buf := append([]byte(nil), pkt...)
	if err := applyHeaderProtection(buf, client.hp, pnOffset, 4, true); err != nil {
		return nil, "", false
	}
	pnLen := int(buf[0]&0x03) + 1
	if pnLen < 4 {
		copy(buf[pnOffset+pnLen:pnOffset+4], pkt[pnOffset+pnLen:pnOffset+4])
	}
	var pn uint32
	for i := 0; i < pnLen; i++ {
		pn = pn<<8 | uint32(buf[pnOffset+i])
	}
	plain, err := open(client, buf[pnOffset+pnLen:pnOffset+int(length)], buf[:pnOffset+pnLen], pn)
	if err != nil {
		return nil, "", false
	}
	// Имя ищем подстрокой — ровно как дешёвая коробка, которая не собирает
	// кадры CRYPTO и не разбирает TLS целиком.
	for _, f := range parseFrames(plain) {
		if f.Type != FrameCrypto {
			continue
		}
		if i := bytes.Index(f.Data, []byte(b.blocked)); i >= 0 {
			return dcid, b.blocked, true
		}
	}
	return dcid, "", true
}

// sendServerInitial собирает НАСТОЯЩИЙ ответ сервера: ACK плюс кадр CRYPTO,
// зашифрованный серверными ключами из клиентского DCID.
func (b *fakeBox) sendServerInitial(dcid []byte, to *net.UDPAddr) {
	_, server, err := deriveKeys(dcid, V1)
	if err != nil {
		return
	}
	payload := []byte{0x02, 0x00, 0x00, 0x00, 0x00} // ACK
	crypto := []byte{0x06}
	crypto = appendVarint(crypto, 0)
	body := []byte{0x02, 0x00, 0x00, 0x56, 0x03, 0x03} // огрызок ServerHello
	crypto = appendVarint(crypto, uint64(len(body)))
	crypto = append(crypto, body...)
	payload = append(payload, crypto...)

	scid := randomID(8)
	hdr := []byte{0xc3}
	hdr = binary.BigEndian.AppendUint32(hdr, uint32(V1))
	hdr = append(hdr, byte(len(dcid)))
	hdr = append(hdr, dcid...)
	hdr = append(hdr, byte(len(scid)))
	hdr = append(hdr, scid...)
	hdr = appendVarint(hdr, 0)
	hdr = binary.BigEndian.AppendUint16(hdr, uint16(4+len(payload)+16)|0x4000)
	pnOffset := len(hdr)
	hdr = appendPacketNumber(hdr, 0, 4)

	sealed, err := seal(server, payload, hdr, 0)
	if err != nil {
		return
	}
	pkt := append(hdr, sealed...)
	if err := applyHeaderProtection(pkt, server.hp, pnOffset, 4, true); err != nil {
		return
	}
	_, _ = b.conn.WriteToUDP(pkt, to)
}

func (b *fakeBox) sendVersionNegotiation(req []byte, to *net.UDPAddr) {
	// Настоящий сервер тоже сперва проверяет границы: на случайный мусор с
	// поднятым старшим битом отвечать нельзя, иначе стенд ответит на зонд,
	// который в поле остался бы без ответа.
	if len(req) < 7 {
		return
	}
	dl := int(req[5])
	if 6+dl >= len(req) {
		return
	}
	dcid := req[6 : 6+dl]
	sl := int(req[6+dl])
	if 7+dl+sl > len(req) {
		return
	}
	scid := req[7+dl : 7+dl+sl]
	// В ответе идентификаторы меняются местами (RFC 9000 §17.2.1).
	out := []byte{0xc0, 0, 0, 0, 0}
	out = append(out, byte(len(scid)))
	out = append(out, scid...)
	out = append(out, byte(len(dcid)))
	out = append(out, dcid...)
	out = binary.BigEndian.AppendUint32(out, uint32(V1))
	_, _ = b.conn.WriteToUDP(out, to)
}

// mustResolve — разбор адреса стенда в *net.UDPAddr.
func mustResolve(t *testing.T, addr string) *net.UDPAddr {
	t.Helper()
	a, err := net.ResolveUDPAddr("udp4", addr)
	if err != nil {
		t.Fatalf("адрес стенда %q не разбирается: %v", addr, err)
	}
	return a
}

func runAgainst(t *testing.T, box *fakeBox, host string) Result {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return Run(ctx, host, Options{
		Addr: box.addr(), Repeats: 3, Timeout: 400 * time.Millisecond,
		AllowLoopback: true, Parallel: 4,
	})
}

// Домен, который коробка не трогает, обязан получить вердикт «чисто», а не
// «ничего не нашли»: это самый частый исход в поле, и путать его нельзя.
func TestProbeSeesClearDomain(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	res := runAgainst(t, box, "example.org")
	if res.Verdict != VerdictClear {
		t.Fatalf("вердикт %q (%s), ожидался %q", res.Verdict, res.Reason, VerdictClear)
	}
}

// Коробка режет имя, но отвечает на соседнее с того же адреса. Это и есть
// «режут по содержимому», и отличить его от блокировки адреса обязан контроль.
func TestProbeSeesContentBlock(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	res := runAgainst(t, box, "rutracker.org")
	if res.Verdict != VerdictContent {
		t.Fatalf("вердикт %q (%s), ожидался %q", res.Verdict, res.Reason, VerdictContent)
	}
}

// Коробка разбирает только первую датаграмму потока. Замер обязан это
// увидеть и выдать исполнимую строку — фальшивку перед настоящим пакетом.
func TestProbeFindsFirstPacketOnly(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	box.firstPacketOnly = true
	res := runAgainst(t, box, "rutracker.org")
	if res.Verdict != VerdictContent {
		t.Fatalf("вердикт %q (%s)", res.Verdict, res.Reason)
	}
	if res.Props.JunkAheadHelps == nil || !*res.Props.JunkAheadHelps {
		t.Errorf("приём «мусор перед Initial» не засчитан: %+v", res.Props)
	}
	if res.Strategy == "" {
		t.Error("свойство измерено, а исполнимой строки нет")
	}
}

// Остаточная блокировка: после срабатывания коробка глушит всё подряд.
// Замер обязан обнаружить это СРАЗУ, иначе все последующие вопросы получат
// тишину и он объявит, что не помогает ничего.
func TestProbeDetectsResidualBlocking(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	box.residual = true
	res := runAgainst(t, box, "rutracker.org")
	if res.Props.ResidualBlocking == nil || !*res.Props.ResidualBlocking {
		t.Fatalf("остаточная блокировка не обнаружена: %+v", res.Props)
	}
	// Адрес один, свежих не осталось — значит вопросы обязаны быть честно
	// помечены как незаданные, а не молча пропущены.
	var skipped bool
	for _, s := range res.Trace {
		if s.Sent == 0 && s.Note != "" {
			skipped = true
		}
	}
	if !skipped {
		t.Error("при остаточной блокировке вопросы должны помечаться незаданными")
	}
}

// Хост не говорит по QUIC вовсе, но путь до него живой. Это НЕ блокировка, и
// выдавать её за блокировку нельзя.
func TestProbeSeesNoQUIC(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	box.answerInitial = false
	res := runAgainst(t, box, "example.org")
	if res.Verdict != VerdictNoQUIC {
		t.Fatalf("вердикт %q (%s), ожидался %q", res.Verdict, res.Reason, VerdictNoQUIC)
	}
}

// Закрытый порт — это НЕ блокировка. ICMP «порт недоступен» доказывает, что
// датаграмма доехала до хоста, а слушателя нет: хост просто не обслуживает
// HTTP/3. Без этого различения инструмент объявлял бы блокировкой каждый сайт
// без поддержки QUIC — а таких большинство.
func TestProbeSeesClosedPort(t *testing.T) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	addr := c.LocalAddr().String()
	_ = c.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	res := Run(ctx, "example.org", Options{
		Addr: addr, Repeats: 2, Timeout: 300 * time.Millisecond,
		AllowLoopback: true, Parallel: 2,
	})
	if res.Verdict != VerdictNoQUIC {
		t.Fatalf("вердикт %q (%s), ожидался %q", res.Verdict, res.Reason, VerdictNoQUIC)
	}
}

// А вот когда молчит ВСЁ, включая согласование версии, и ICMP не приходит —
// это уже блокировка адреса, и десинком она не лечится.
func TestProbeSeesAddressBlock(t *testing.T) {
	box := newFakeBox(t, "rutracker.org")
	box.silent = true
	res := runAgainst(t, box, "example.org")
	if res.Verdict != VerdictAddress {
		t.Fatalf("вердикт %q (%s), ожидался %q", res.Verdict, res.Reason, VerdictAddress)
	}
}
