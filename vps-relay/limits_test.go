package main

import (
	"testing"
)

// До 2026-08-08 потолков не было вовсе: на каждый входящий кадр CONNECT
// поднималась горутина без счётчика, а число стримов ограничивала только
// разрядность uint16 (65536 в одной сессии). Кадр CONNECT — десять байт,
// горутина живёт до 3 с ожидания слота плюс два диала по 10 с. То есть один
// аутентифицированный клиент покупал себе десятки тысяч горутин и гигабайты
// буферов на машине, где всего 2 ГБ.

func TestConnectSlotsCapInFlight(t *testing.T) {
	withInts(t, maxPendingConnects, 3)

	s := &session{connectSlots: newConnectSlots()}

	for i := 1; i <= 3; i++ {
		if !s.acquireConnectSlot() {
			t.Fatalf("слот %d должен был взяться (потолок 3)", i)
		}
	}
	if s.acquireConnectSlot() {
		t.Fatal("четвёртый слот при потолке 3 браться не должен")
	}

	// Освободили один — снова можно ровно один.
	s.releaseConnectSlot()
	if !s.acquireConnectSlot() {
		t.Fatal("после освобождения слот должен браться")
	}
	if s.acquireConnectSlot() {
		t.Fatal("сверх потолка брать нельзя даже после освобождения одного")
	}
}

// Ноль означает «без ограничения» — это путь отката, если потолок вдруг
// окажется тесен в поле. Он обязан работать, иначе откатываться будет некуда.
func TestConnectSlotsUnlimitedWhenZero(t *testing.T) {
	withInts(t, maxPendingConnects, 0)

	s := &session{connectSlots: newConnectSlots()}
	if s.connectSlots != nil {
		t.Fatal("при потолке 0 канал слотов должен быть nil")
	}
	for i := 0; i < 1000; i++ {
		if !s.acquireConnectSlot() {
			t.Fatalf("без лимита слот %d обязан браться", i)
		}
	}
	// release на nil-канале не должен паниковать.
	s.releaseConnectSlot()
}

// Освобождение лишний раз не должно «накапливать» слоты сверх ёмкости:
// иначе двойной release где-нибудь в обработчике тихо снял бы потолок.
func TestReleaseConnectSlotIsSafeWhenEmpty(t *testing.T) {
	withInts(t, maxPendingConnects, 2)

	s := &session{connectSlots: newConnectSlots()}
	s.releaseConnectSlot()
	s.releaseConnectSlot()
	s.releaseConnectSlot()

	if !s.acquireConnectSlot() || !s.acquireConnectSlot() {
		t.Fatal("после лишних release потолок должен остаться прежним (2)")
	}
	if s.acquireConnectSlot() {
		t.Fatal("лишние release не должны расширять потолок")
	}
}
