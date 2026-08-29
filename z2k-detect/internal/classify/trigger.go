package classify

import (
	"bytes"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// TLSTrigger собирает НАСТОЯЩИЙ ClientHello для указанного имени.
//
// Хелло не конструируется руками намеренно. Форма приветствия — это и есть
// измерительный инструмент: DPI решает по ней, и самодельный хелло с другим
// набором расширений мерил бы не ту коробку, что видит браузер. Поэтому
// приветствие берётся у той же crypto/tls, что стоит в проберах z2k: поднимаем
// клиента над трубой и забираем первую запись, которую он пишет.
func TLSTrigger(sni string) (Trigger, error) {
	if sni == "" {
		return Trigger{}, errors.New("classify: пустой SNI")
	}
	client, server := net.Pipe()
	captured := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 8192)
		_ = server.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _ := io.ReadAtLeast(server, buf, 1)
		captured <- append([]byte(nil), buf[:n]...)
		// Рукопожатию не дают завершиться намеренно: нам нужна первая
		// запись, а не сессия.
		_ = server.Close()
	}()
	c := tls.Client(client, &tls.Config{ServerName: sni, MinVersion: tls.VersionTLS12})
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	_ = c.Handshake() // ошибка ожидаема: труба закроется сразу после захвата
	_ = client.Close()

	select {
	case b := <-captured:
		if len(b) < 16 {
			return Trigger{}, fmt.Errorf("classify: ClientHello вышел длиной %d байт", len(b))
		}
		t := Trigger{
			Name:    "tls:" + sni,
			Payload: b,
			Accept:  acceptServerHello,
		}
		// Запоминаем, где в приветствии лежит имя: по нему режут, а не по
		// середине пакета.
		if i := bytes.Index(b, []byte(sni)); i >= 0 {
			t.SNIOffset, t.SNILen = i, len(sni)
		}
		return t, nil
	case <-time.After(3 * time.Second):
		return Trigger{}, errors.New("classify: не удалось собрать ClientHello")
	}
}

// acceptServerHello — доказательством прохода считается ТОЛЬКО ServerHello.
//
// Фатальный алерт сюда не годится, хотя это тоже ответ: его инжектируют и сами
// коробки, и засчитав его за успех мы объявили бы блокировку обходом.
func acceptServerHello(b []byte) bool {
	// TLS record: type 0x16 (handshake), version 0x03xx, len, затем
	// handshake type 0x02 (server_hello).
	return len(b) >= 6 && b[0] == 0x16 && b[1] == 0x03 && b[5] == 0x02
}

// RawTrigger — произвольные байты, заданные шестнадцатеричной строкой.
//
// Нужен для протоколов, у которых нет ни TLS, ни имени хоста в пакете:
// пролог WhatsApp ("WA\x06\x03" плюс рукопожатие Noise) снимается из дампа и
// подаётся сюда как есть. Доказательством прохода тогда считается любой
// непустой ответ: разбирать чужой протокол ради вердикта незачем, важно лишь,
// ответил сервер или промолчал.
func RawTrigger(hexBytes string) (Trigger, error) {
	clean := strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\t', '\n', '\r', ':', '-':
			return -1
		}
		return r
	}, hexBytes)
	b, err := hex.DecodeString(clean)
	if err != nil {
		return Trigger{}, fmt.Errorf("classify: триггер не разобран как hex: %w", err)
	}
	if len(b) < 2 {
		return Trigger{}, errors.New("classify: триггер короче двух байт")
	}
	return Trigger{
		Name:    fmt.Sprintf("raw:%dB", len(b)),
		Payload: b,
		Accept:  func(r []byte) bool { return len(r) > 0 },
	}, nil
}

// ControlTrigger — заведомо безобидное приветствие на ту же цель.
//
// Имя намеренно случайное и явно не из блок-листов: нам не нужен успешный
// сеанс, нужен ФАКТ, что наши байты дошли до TLS-сервера и он на них
// отреагировал. Поэтому доказательством прохода тут считается ЛЮБАЯ запись
// TLS, включая алерт: сервер, отвечающий отказом на незнакомое имя, — это
// всё равно сервер, до которого дошли. А вот тишина означает, что до него не
// дошло ничего, и тогда дело не в содержимом.
func ControlTrigger(tag string) (Trigger, error) {
	tr, err := TLSTrigger("probe-" + tag + ".invalid-control.example")
	if err != nil {
		return Trigger{}, err
	}
	tr.Name = "control"
	tr.Accept = func(b []byte) bool {
		return len(b) >= 3 && (b[0] == 0x16 || b[0] == 0x15) && b[1] == 0x03
	}
	return tr, nil
}
