package main

import (
	"errors"
	"os"
	"strings"
	"testing"
)

// Клиент НЕ ДОЛЖЕН ходить на релей общим секретом.
//
// Полевой случай 2026-08-17 (issue #34, «Telegram постоянно Подключение…»):
// на релее 5900 отказов в час с 78 адресов при одной успешной регистрации за
// тот же час. Причина — фоллбэк в connectTunnelWS: пока личность не
// зарегистрирована, клиент подключался старой схемой (тип 0x00, общий
// секрет). Комментарий рядом уверял, что «релей принимает обе схемы», но
// релей давно поднят с --require-per-install и старую отвергает наглухо.
// Получался вечный цикл «подключился → отвергнут → переподключился» по разу
// в 48 секунд, и телеграм у человека не поднимался никогда.
//
// Тест сторожит сам факт: незарегистрированная установка не подключается
// вовсе, а ждёт регистрацию.
func TestNoSharedSecretFallback(t *testing.T) {
	tc := &tunnelClient{}
	// Личности нет — так выглядит свежая установка до регистрации.
	_, err := tc.connectTunnelWS()
	if !errors.Is(err, errNotRegistered) {
		t.Fatalf("без личности ожидался errNotRegistered, получено: %v", err)
	}

	// Личность есть, но регистрация ещё не прошла (useID=false) — это ровно
	// то состояние, в котором старый код лез на релей общим секретом.
	id, err := loadOrMintIdentity(t.TempDir() + "/relay-id")
	if err != nil {
		t.Fatalf("loadOrMintIdentity: %v", err)
	}
	tc.identity.Store(id)
	_, err = tc.connectTunnelWS()
	if !errors.Is(err, errNotRegistered) {
		t.Fatalf("до регистрации ожидался errNotRegistered, получено: %v", err)
	}
}

// И вторая половина того же: в коде подключения не должно остаться ни одного
// места, где собирается кадр авторизации типа 0x00. Проверка по исходнику —
// потому что вернуть фоллбэк проще всего именно туда, откуда его убрали.
func TestAuthFrameTypeIsPerInstallOnly(t *testing.T) {
	raw, err := os.ReadFile("tunnel.go")
	if err != nil {
		t.Fatalf("не прочитать tunnel.go: %v", err)
	}
	src := string(raw)
	if strings.Contains(src, "computeAuthHMAC(tc.tunnelSecret)") {
		t.Fatal("в tunnel.go снова собирается кадр авторизации общим секретом — релей его отвергает")
	}
	if !strings.Contains(src, "encodeMuxFrame(0x0000, muxAUTHID,") || !strings.Contains(src, "encodeMuxFrame(0, muxAUTHID, id.authPayloadV2(") {
		t.Fatal("персональная авторизация (0x06) пропала из подключения")
	}
}
