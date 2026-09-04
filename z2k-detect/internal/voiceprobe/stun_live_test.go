package voiceprobe

import (
	"net"
	"os"
	"testing"
	"time"
)

// Живая проверка против настоящего сервера STUN.
//
// Офлайновые тесты доказывают, что мы согласованы САМИ С СОБОЙ: сами собрали,
// сами разобрали. Ошибку в порядке полей или в ксоре они не поймают — она
// зеркальна. Ловит её только чужая реализация.
//
// В общий прогон не входит: CI обязан быть герметичным, а тут нужна сеть.
// Запуск: Z2K_NET_TESTS=1 go test -run Live ./internal/voiceprobe/
func TestLiveStunAgainstPublicServer(t *testing.T) {
	if os.Getenv("Z2K_NET_TESTS") == "" {
		t.Skip("нужна сеть; включается Z2K_NET_TESTS=1")
	}
	// Достаточно ОДНОГО ответившего сервера: тест доказывает нашу
	// корректность, а не идеальность канала. Замер 04.09 с роутера Марка:
	// Cloudflare на 3478 отвечает, Google на 19302 молчит — и это факт про
	// сеть (порт 19302 входит в диапазон, который у нас же и фильтруется),
	// а не повод считать реализацию сломанной.
	servers := []string{"stun.cloudflare.com:3478", "stun.l.google.com:19302"}
	answered := 0
	for _, srv := range servers {
		// Метка ОБЯЗАТЕЛЬНА: порты STUN входят в диапазоны нашего же профиля
		// discord_udp, и без неё зонд меряет собственный обход. Замер 04.09:
		// без метки запрос на 20 байт уходил в провод датаграммой на 1200 —
		// nfqws2 подставлял фальшивку.
		d := net.Dialer{Control: markControl, Timeout: 5 * time.Second}
		c, err := d.Dial("udp4", srv)
		if err != nil {
			t.Logf("%s: не подключиться: %v", srv, err)
			continue
		}
		req, tx := BindingRequest()
		if _, err := c.Write(req); err != nil {
			t.Logf("%s: отправка: %v", srv, err)
			_ = c.Close()
			continue
		}
		_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
		buf := make([]byte, 1500)
		n, err := c.Read(buf)
		_ = c.Close()
		if err != nil {
			t.Logf("%s: ответа нет (%v)", srv, err)
			continue
		}
		ip, port, err := ParseBindingResponse(buf[:n], tx)
		if err != nil {
			t.Errorf("%s: ответ пришёл, но не разобрался: %v", srv, err)
			continue
		}
		if ip == nil || port == 0 {
			t.Errorf("%s: ответ разобран, но адреса в нём нет", srv)
			continue
		}
		t.Logf("%s увидел нас как %s:%d", srv, ip, port)
		answered++
	}
	if answered == 0 {
		t.Skip("ни один сервер STUN не ответил — на этом канале проверить нечем")
	}
}
