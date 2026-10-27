package classify

import (
	"bytes"
	"errors"
	"testing"
)

func TestResolveV4(t *testing.T) {
	ip, port, err := resolveV4("127.0.0.1:443")
	if err != nil || ip.String() != "127.0.0.1" || port != 443 {
		t.Fatalf("127.0.0.1:443 → %v %d %v", ip, port, err)
	}
	if _, port, err := resolveV4("127.0.0.1:65535"); err != nil || port != 65535 {
		t.Fatalf("верхний порт: %d %v", port, err)
	}
	if _, port, err := resolveV4("127.0.0.1:1"); err != nil || port != 1 {
		t.Fatalf("нижний порт: %d %v", port, err)
	}
	for _, bad := range []string{"127.0.0.1", "127.0.0.1:0", "127.0.0.1:70000", "127.0.0.1:x", "[::1]:443"} {
		if _, _, err := resolveV4(bad); err == nil {
			t.Errorf("%q принят, ожидалась ошибка", bad)
		}
	}
}

func TestDecoyFill(t *testing.T) {
	if got := decoyFill(4, nil); !bytes.Equal(got, []byte{0x0f, 0x0f, 0x0f, 0x0f}) {
		t.Fatalf("без приманки: %x", got)
	}
	if got := decoyFill(4, []byte("ab")); !bytes.Equal(got, []byte{'a', 'b', 0x0f, 0x0f}) {
		t.Fatalf("короткая приманка: %x", got)
	}
	if got := decoyFill(2, []byte("abcd")); !bytes.Equal(got, []byte("ab")) {
		t.Fatalf("длинная приманка обрезается: %x", got)
	}
}

func TestMidSplit(t *testing.T) {
	pay := make([]byte, 100)
	if got := midSplit(Trigger{Payload: pay}); got != 50 {
		t.Fatalf("без имени — пополам: %d", got)
	}
	// Имя с 60 по 80: разрез падает внутрь имени, а не в середину пакета.
	if got := midSplit(Trigger{Payload: pay, SNIOffset: 60, SNILen: 20}); got != 70 {
		t.Fatalf("по имени: %d", got)
	}
	if got := midSplit(Trigger{Payload: pay[:3]}); got != 2 {
		t.Fatalf("нижняя граница: %d", got)
	}
	if got := midSplit(Trigger{Payload: pay, SNIOffset: 95, SNILen: 20}); got != 99 {
		t.Fatalf("верхняя граница: %d", got)
	}
	if got := midSplit(Trigger{Payload: pay, SNIOffset: 95, SNILen: 10}); got != 99 {
		t.Fatalf("разрез ровно в конец — тоже за границей: %d", got)
	}
	// Имя из одного байта или с нулевым смещением — не имя: режем пополам.
	if got := midSplit(Trigger{Payload: pay, SNIOffset: 10, SNILen: 1}); got != 50 {
		t.Fatalf("SNILen=1: %d", got)
	}
	if got := midSplit(Trigger{Payload: pay, SNIOffset: 0, SNILen: 20}); got != 50 {
		t.Fatalf("SNIOffset=0: %d", got)
	}
	if got := midSplit(Trigger{Payload: pay, SNIOffset: 1, SNILen: 20}); got != 11 {
		t.Fatalf("SNIOffset=1 — уже имя: %d", got)
	}
}

func TestObservationNote(t *testing.T) {
	var obs Observation
	obs.note(true, nil)
	obs.note(false, nil)
	obs.note(false, errors.New("первая"))
	obs.note(false, errors.New("вторая"))
	if obs.Pass != 1 || obs.Fail != 3 || obs.Err != "первая" {
		t.Fatalf("pass=%d fail=%d err=%q", obs.Pass, obs.Fail, obs.Err)
	}
}
