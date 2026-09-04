package quicprobe

import (
	"encoding/binary"
	"net"
	"testing"
)

// Арифметика разрезов обязана совпадать с z2k_ipfrag3_params из
// files/lua/z2k-modern-core.lua построчно. Расхождение здесь — это зонд,
// который меряет один разрез, а конфиг делает другой: находка не
// воспроизведётся, и понять почему будет нечем.
func TestPlanCutsMatchesEngine(t *testing.T) {
	const total = 1208 // 8 байт заголовка UDP плюс датаграмма 1200

	t.Run("штатный ipfrag: заголовок отдельно от содержимого", func(t *testing.T) {
		cuts, err := planCuts(total, fragPlan{pos1: 8})
		if err != nil {
			t.Fatal(err)
		}
		want := []cut{{0, 8}, {8, total - 8}}
		if len(cuts) != 2 || cuts[0] != want[0] || cuts[1] != want[1] {
			t.Fatalf("получено %+v, ожидалось %+v", cuts, want)
		}
	})

	t.Run("позиция выравнивается по восьми байтам", func(t *testing.T) {
		cuts, err := planCuts(total, fragPlan{pos1: 30})
		if err != nil {
			t.Fatal(err)
		}
		if cuts[0].len != 24 {
			t.Errorf("первый фрагмент %d байт, ожидалось 24 (30 вниз до кратного восьми)", cuts[0].len)
		}
	})

	t.Run("z2k_ipfrag3_tiny из боевого плеча", func(t *testing.T) {
		// --lua-desync=send:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:
		//   ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8
		cuts, err := planCuts(total, fragPlan{three: true, pos1: 8, pos2: 32, ov12: 8, ov23: 8})
		if err != nil {
			t.Fatal(err)
		}
		// ov12 зажимается до pos1-8 = 0, значит off2 = 8; off3 = 32-8 = 24.
		want := []cut{{0, 8}, {8, 24}, {24, total - 24}}
		for i := range want {
			if cuts[i] != want[i] {
				t.Fatalf("фрагмент %d = %+v, ожидался %+v (все: %+v)", i, cuts[i], want[i], cuts)
			}
		}
	})

	t.Run("z2k_ipfrag3 с перекрытием даёт пересекающиеся фрагменты", func(t *testing.T) {
		// ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8
		cuts, err := planCuts(total, fragPlan{three: true, pos1: 16, pos2: 48, ov12: 8, ov23: 8})
		if err != nil {
			t.Fatal(err)
		}
		want := []cut{{0, 16}, {8, 40}, {40, total - 40}}
		for i := range want {
			if cuts[i] != want[i] {
				t.Fatalf("фрагмент %d = %+v, ожидался %+v (все: %+v)", i, cuts[i], want[i], cuts)
			}
		}
		// Перекрытие — суть приёма: второй фрагмент обязан начинаться раньше,
		// чем кончился первый.
		if cuts[1].off >= cuts[0].off+cuts[0].len {
			t.Error("перекрытия нет — приём вырождается в обычную нарезку")
		}
	})

	t.Run("слишком короткая датаграмма отвергается, а не режется криво", func(t *testing.T) {
		if _, err := planCuts(20, fragPlan{three: true, pos1: 8}); err == nil {
			t.Error("на 20 байтах три фрагмента собрались, хотя не должны")
		}
		if _, err := planCuts(4, fragPlan{pos1: 8}); err == nil {
			t.Error("разрез за пределами датаграммы не отвергнут")
		}
	})
}

// Фрагменты должны собираться обратно в исходную датаграмму, а заголовки —
// быть корректными. Иначе сервер выбросит их молча, и это будет неотличимо от
// блокировки.
func TestBuildFragmentsReassemble(t *testing.T) {
	src, dst := net.IPv4(10, 0, 0, 1), net.IPv4(93, 184, 216, 34)
	payload := make([]byte, 1200)
	for i := range payload {
		payload[i] = byte(i)
	}
	frags, err := buildFragments(src, dst, 51234, 443, payload, fragPlan{pos1: 8}, 0x1234)
	if err != nil {
		t.Fatal(err)
	}
	if len(frags) != 2 {
		t.Fatalf("фрагментов %d, ожидалось 2", len(frags))
	}

	reasm := make([]byte, 0, 1208)
	for i, f := range frags {
		if len(f) < 20 {
			t.Fatalf("фрагмент %d короче заголовка", i)
		}
		if f[0] != 0x45 {
			t.Errorf("фрагмент %d: первый байт %#x, ожидался 0x45", i, f[0])
		}
		if id := binary.BigEndian.Uint16(f[4:]); id == 0 {
			t.Errorf("фрагмент %d: нулевой идентификатор — ядро подставит свой и сборка развалится", i)
		}
		flags := binary.BigEndian.Uint16(f[6:])
		more := flags&0x2000 != 0
		if want := i == 0; more != want {
			t.Errorf("фрагмент %d: флаг MF %v, ожидался %v", i, more, want)
		}
		if off := int(flags&0x1fff) * 8; off != len(reasm) {
			t.Errorf("фрагмент %d: смещение %d, ожидалось %d", i, off, len(reasm))
		}
		if got := checksum(f[:20]); got != 0 {
			t.Errorf("фрагмент %d: контрольная сумма заголовка не сходится (%#x)", i, got)
		}
		reasm = append(reasm, f[20:]...)
	}

	if n := binary.BigEndian.Uint16(reasm[4:]); int(n) != 8+len(payload) {
		t.Errorf("длина UDP %d, ожидалась %d", n, 8+len(payload))
	}
	if got := string(reasm[8:]); got != string(payload) {
		t.Error("после сборки содержимое не совпало с исходным")
	}
	if binary.BigEndian.Uint16(reasm[6:]) == 0 {
		t.Error("контрольная сумма UDP нулевая — приёмник примет её за «не считана»")
	}
}

// Обратный порядок — отдельный приём, а не косметика: коробка, собирающая по
// мере поступления, увидит хвост раньше головы.
func TestFragmentDisorderReversesOrder(t *testing.T) {
	src, dst := net.IPv4(10, 0, 0, 1), net.IPv4(93, 184, 216, 34)
	payload := make([]byte, 1200)
	straight, err := buildFragments(src, dst, 5000, 443, payload, fragPlan{pos1: 8}, 1)
	if err != nil {
		t.Fatal(err)
	}
	reversed, err := buildFragments(src, dst, 5000, 443, payload,
		fragPlan{pos1: 8, disorder: true}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if binary.BigEndian.Uint16(straight[0][6:])&0x1fff != 0 {
		t.Error("прямой порядок: первым идёт не нулевой фрагмент")
	}
	if binary.BigEndian.Uint16(reversed[0][6:])&0x1fff == 0 {
		t.Error("обратный порядок: первым всё равно идёт нулевой фрагмент")
	}
}
