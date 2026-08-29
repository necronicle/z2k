package classify

import (
	"bytes"
	"context"
	"io"
	"net"
	"testing"
	"time"
)

// Полезная нагрузка теста: первые sigLen байт играют роль открытой сигнатуры.
var payload = []byte("WA\x06\x03SIGNATURE-AND-THEN-SOME-PAYLOAD-BYTES")

// fakeDPI — сервер, ведущий себя как коробка заданного класса.
//
// mode:
//
//	"prefix"  — молчит, если ПЕРВЫЙ сегмент начинается с сигнатуры;
//	"whole"   — молчит, только если первый сегмент это вся нагрузка целиком;
//	"reasm"   — склеивает всё прочитанное и молчит, если сигнатура нашлась
//	            где угодно (то есть разрез её не спасает);
//	"clear"   — отвечает всегда.
func fakeDPI(t *testing.T, mode string, sigLen int) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(3 * time.Second))
				buf := make([]byte, 4096)
				n, err := c.Read(buf)
				if err != nil {
					return
				}
				first := append([]byte(nil), buf[:n]...)
				blocked := false
				switch mode {
				case "prefix":
					blocked = len(first) >= sigLen && bytes.Equal(first[:sigLen], payload[:sigLen])
				case "whole":
					blocked = bytes.Equal(first, payload)
				case "reasm":
					// Дочитываем остаток и ищем сигнатуру в склейке.
					all := first
					_ = c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
					for {
						m, err := c.Read(buf)
						if m > 0 {
							all = append(all, buf[:m]...)
						}
						if err != nil {
							break
						}
					}
					blocked = bytes.Contains(all, payload[:sigLen])
				case "clear":
					blocked = false
				case "deaf":
					// Режет всё подряд: имитация блока по адресу.
					blocked = true
				}
				if blocked {
					// Блокировка — это молчание, а не отказ.
					time.Sleep(2 * time.Second)
					return
				}
				_, _ = io.WriteString(c, "SERVER-ANSWER")
			}(c)
		}
	}()
	return ln.Addr().String()
}

func fastOpts() Options {
	return Options{
		// Поддельная коробка живёт на loopback — защиту от неверно
		// разрезолвившегося имени здесь снимаем осознанно.
		AllowLoopback: true,
		Repeats:       2,
		Timeout:       900 * time.Millisecond,
		WriteGap:      10 * time.Millisecond,
		LongGap:       40 * time.Millisecond,
	}
}

func trig() Trigger {
	return Trigger{Name: "test", Payload: payload, Accept: func(b []byte) bool { return len(b) > 0 }}
}

func TestPrefixMatcherFindsBoundary(t *testing.T) {
	addr := fakeDPI(t, "prefix", 4)
	res := Run(context.Background(), addr, trig(), fastOpts())
	if res.Verdict != VerdictPrefix {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictPrefix)
	}
	// Сигнатура длиной 4: разрез на 1..3 её ломает, на 4 и правее — нет.
	if res.Boundary != 4 {
		t.Errorf("граница = %d, ждали 4", res.Boundary)
	}
	if res.SplitPos != 1 {
		t.Errorf("SplitPos = %d, ждали 1", res.SplitPos)
	}
	if res.Strategy == "" {
		t.Error("стратегия не заполнена")
	}
}

func TestPrefixBoundaryDeeperSignature(t *testing.T) {
	addr := fakeDPI(t, "prefix", 9)
	res := Run(context.Background(), addr, trig(), fastOpts())
	if res.Verdict != VerdictPrefix {
		t.Fatalf("вердикт = %s (%s)", res.Verdict, res.Reason)
	}
	if res.Boundary != 9 {
		t.Errorf("граница = %d, ждали 9", res.Boundary)
	}
}

func TestWholePacketMatcher(t *testing.T) {
	addr := fakeDPI(t, "whole", 0)
	res := Run(context.Background(), addr, trig(), fastOpts())
	if res.Verdict != VerdictWholePacket {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictWholePacket)
	}
	if res.SplitPos != 1 {
		t.Errorf("SplitPos = %d, ждали 1", res.SplitPos)
	}
}

func TestReassemblingBoxIsOpaque(t *testing.T) {
	addr := fakeDPI(t, "reasm", 4)
	res := Run(context.Background(), addr, trig(), fastOpts())
	if res.Verdict != VerdictOpaque {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictOpaque)
	}
	if res.Strategy != "" {
		t.Errorf("для непрозрачной коробки стратегия предлагаться не должна, а стоит %q", res.Strategy)
	}
}

func TestClearTargetStopsEarly(t *testing.T) {
	addr := fakeDPI(t, "clear", 0)
	res := Run(context.Background(), addr, trig(), fastOpts())
	if res.Verdict != VerdictClear {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictClear)
	}
	// Смысл ранней остановки: если резать нечего, дерево дальше не идёт.
	if res.Probes != 2 {
		t.Errorf("зондов = %d, ждали ровно 2 (только база)", res.Probes)
	}
}

func TestUnreachableTarget(t *testing.T) {
	res := Run(context.Background(), "127.0.0.1:1", trig(), fastOpts())
	if res.Verdict != VerdictUnreachable {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictUnreachable)
	}
}

func TestSplitOffsetsIgnoresOutOfRangeCuts(t *testing.T) {
	// Разрез в нуле и в длине — это не разрез; такие точки обязаны отсеиваться,
	// иначе двоичный поиск на краю выродится в запись нулевой длины.
	got := splitOffsets([]int{0, 3, 3, 10, 99}, 10)
	want := []span{{0, 3}, {3, 10}}
	if len(got) != len(want) {
		t.Fatalf("кусков = %d (%v), ждали %d", len(got), got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("кусок %d = %v, ждали %v", i, got[i], want[i])
		}
	}
}

func TestRawTriggerParsesAndRejectsGarbage(t *testing.T) {
	tr, err := RawTrigger("57 41 06 03")
	if err != nil {
		t.Fatalf("hex с пробелами не разобран: %v", err)
	}
	if !bytes.Equal(tr.Payload, []byte{0x57, 0x41, 0x06, 0x03}) {
		t.Errorf("нагрузка = % x", tr.Payload)
	}
	if _, err := RawTrigger("нехекс"); err == nil {
		t.Error("мусор обязан отвергаться")
	}
	if _, err := RawTrigger("57"); err == nil {
		t.Error("триггер в один байт обязан отвергаться")
	}
}

func TestTLSTriggerLooksLikeClientHello(t *testing.T) {
	tr, err := TLSTrigger("example.com")
	if err != nil {
		t.Fatalf("TLSTrigger: %v", err)
	}
	if tr.Payload[0] != 0x16 || tr.Payload[1] != 0x03 {
		t.Fatalf("это не TLS-запись рукопожатия: % x", tr.Payload[:4])
	}
	if !bytes.Contains(tr.Payload, []byte("example.com")) {
		t.Error("SNI не попал в приветствие")
	}
	// Алерт за успех не считаем — иначе инжект коробки прошёл бы за ответ.
	if acceptServerHello([]byte{0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28}) {
		t.Error("фатальный алерт засчитан как ServerHello")
	}
	if !acceptServerHello([]byte{0x16, 0x03, 0x03, 0x00, 0x50, 0x02}) {
		t.Error("настоящий ServerHello не засчитан")
	}
}

// Контроль отделяет «режут наши байты» от «режут адрес». Без него оба случая
// сливались в один вердикт, а лечатся они противоположным: первый — фейком и
// seqovl, второй не лечится десинком вообще.
func TestReassemblingBoxWithControlStaysOpaque(t *testing.T) {
	addr := fakeDPI(t, "reasm", 4)
	opt := fastOpts()
	opt.Control = Trigger{Name: "ctl", Payload: []byte("BENIGN-CONTROL-PAYLOAD"),
		Accept: func(b []byte) bool { return len(b) > 0 }}
	res := Run(context.Background(), addr, trig(), opt)
	if res.Verdict != VerdictOpaque {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictOpaque)
	}
	var sawControl bool
	for _, o := range res.Trace {
		if o.Probe == "control" && o.Pass == opt.Repeats {
			sawControl = true
		}
	}
	if !sawControl {
		t.Error("контрольный зонд не отработал или не прошёл")
	}
}

func TestAddressBlockIsNotCalledOpaque(t *testing.T) {
	// Коробка глушит ВСЁ на этом адресе, включая безобидное. Содержимое ни при
	// чём, и предлагать стратегию тут — врать человеку.
	addr := fakeDPI(t, "deaf", 0)
	opt := fastOpts()
	opt.Control = Trigger{Name: "ctl", Payload: []byte("BENIGN-CONTROL-PAYLOAD"),
		Accept: func(b []byte) bool { return len(b) > 0 }}
	// За контрольное имя ручается оператор — только тогда молчание контроля
	// означает блок по адресу, а не «сервер не отдаёт это имя».
	opt.ControlVouched = true
	res := Run(context.Background(), addr, trig(), opt)
	if res.Verdict != VerdictAddress {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictAddress)
	}
	if res.Strategy != "" {
		t.Errorf("для блока по адресу стратегия предлагаться не должна, стоит %q", res.Strategy)
	}
}

// Без поручительства за контроль вердикт «режут по адресу» выноситься НЕ
// должен. Поле 2026-08-28, googlevideo: контроль со случайным именем получил
// тишину, инструмент объявил блок по адресу — а тот же адрес с нашим обходом
// отдавал ServerHello за 292 мс. Утверждение было противоположно правде.
func TestAddressNeedsVouchedControl(t *testing.T) {
	addr := fakeDPI(t, "deaf", 0)
	opt := fastOpts()
	opt.Control = Trigger{Name: "ctl", Payload: []byte("BENIGN-CONTROL-PAYLOAD"),
		Accept: func(b []byte) bool { return len(b) > 0 }}
	res := Run(context.Background(), addr, trig(), opt)
	if res.Verdict != VerdictInconclusive {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictInconclusive)
	}
	if res.Strategy != "" {
		t.Errorf("без базы стратегия предлагаться не должна, стоит %q", res.Strategy)
	}
}

func TestLoopbackGuardRejectsMisresolvedTarget(t *testing.T) {
	res := Run(context.Background(), "127.0.0.1:443", trig(), Options{Repeats: 1})
	if res.Verdict != VerdictFlaky {
		t.Fatalf("вердикт = %s (%s), ждали %s", res.Verdict, res.Reason, VerdictFlaky)
	}
}
