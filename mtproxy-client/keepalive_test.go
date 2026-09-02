package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Обрыв пути к релею обязан замечаться быстро.
//
// 02.09.2026 08:17 UTC: транзит между частью операторов и Aeza лёг на
// полторы минуты, 530 сессий из 1830 упали. Клиент замечал обрыв только
// через 90 секунд молчания (пинг раз в 30 с, таймаут чтения 90 с), плюс
// 10 секунд на неудачный дозвон, плюс backoff — итого около двух минут
// без Telegram на каждое такое событие, а событий было три за 32 часа.
//
// Тест исполняет настоящий configureWSKeepalive против сервера, который
// после апгрейда молчит и на пинги не отвечает. Требование — из инцидента:
// клиент обязан отдать ошибку чтения не позже чем через 40 секунд.
func TestSilentRelayDetectedWithin40s(t *testing.T) {
	if testing.Short() {
		t.Skip("ждёт настоящий таймаут чтения")
	}
	up := websocket.Upgrader{}
	hold := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		// Молчим: не читаем (пинги остаются без понга), не пишем.
		<-hold
		ws.Close()
	}))
	defer srv.Close()
	defer close(hold)

	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer ws.Close()
	configureWSKeepalive(ws)

	// Тот же цикл пингов, что в run(): пинг раз в wsPingInterval.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		tk := time.NewTicker(wsPingInterval)
		defer tk.Stop()
		for {
			select {
			case <-tk.C:
				_ = ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
			case <-stop:
				return
			}
		}
	}()

	started := time.Now()
	_, _, err = ws.ReadMessage()
	took := time.Since(started)
	if err == nil {
		t.Fatal("чтение вернулось без ошибки, хотя релей молчал")
	}
	ne, ok := err.(net.Error)
	if !ok || !ne.Timeout() {
		t.Fatalf("ожидался таймаут чтения, получено: %v", err)
	}
	if took > 40*time.Second {
		t.Fatalf("обрыв замечен через %s — дольше 40 с, простой на каждое событие снова ~2 минуты", took.Round(time.Second))
	}
	if took < wsReadTimeout-2*time.Second {
		t.Fatalf("чтение отвалилось через %s, раньше wsReadTimeout=%s — таймаут не тот", took.Round(time.Second), wsReadTimeout)
	}
}

// Три пропущенных понга подряд — минимум, ниже которого один потерянный
// пакет на мобильной линии уже рвёт туннель.
func TestPingIntervalLeavesThreeChances(t *testing.T) {
	if wsPingInterval*3 > wsReadTimeout {
		t.Fatalf("wsPingInterval=%s ×3 > wsReadTimeout=%s: один потерянный понг рвёт сессию", wsPingInterval, wsReadTimeout)
	}
}
