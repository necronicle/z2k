package classify

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

// Зонд объёма: доезжает ли ответ целиком.
//
// ЗАЧЕМ ОТДЕЛЬНО ОТ ОСТАЛЬНОГО ДЕРЕВА. Все прочие зонды спрашивают одно:
// прошло ли РУКОПОЖАТИЕ. Для блокировок по сигнатуре этого хватает — там
// ClientHello либо доехал, либо нет. Но есть класс, где рукопожатие проходит
// безупречно, первые килобайты идут, а поток умирает на 16–19 КБ. Человек
// видит «сайт открывается и не грузится», а классификатор — уверенное
// «чисто», и оба правы про своё.
//
// Поле 2026-08-29: cloudflare.com на обоих адресах дал `clear`, и это была
// правда про рукопожатие и неправда про жизнь.
//
// ПОЧЕМУ НЕ НАДО ЗНАТЬ РАЗМЕР ЗАРАНЕЕ. Его объявляет сам сервер в
// Content-Length, и сравнение «получено против объявленного» точнее любых
// косвенных признаков. Там, где длину не объявили (chunked), судим по
// закрытию — и оно здесь надёжно, в отличие от пассивного наблюдения:
// запрос наш, и `Connection: close` обязывает сервер закрыть соединение по
// окончании ответа. Именно кейс-алайв и погубил идею FIN на чужом трафике
// (замер: FIN приходит лишь у 8% потоков 16–32 КБ), а на своём запросе его
// просто нет.
type Transfer struct {
	Host          string `json:"host"`
	Addr          string `json:"addr"`
	Verdict       string `json:"verdict"`
	Reason        string `json:"reason"`
	Status        int    `json:"status,omitempty"`
	ContentLength int    `json:"content_length,omitempty"`
	BodyBytes     int    `json:"body_bytes"`
	TotalBytes    int    `json:"total_bytes"`
	ClosedByPeer  bool   `json:"closed_by_peer"`
	Chunked       bool   `json:"chunked,omitempty"`
	Location      string `json:"location,omitempty"`
	DurationMS    int64  `json:"duration_ms"`
}

// Границы задокументированного троттлинга: поток отдаёт первые ~16 КБ и
// умирает. База знаний проекта: «останавливается около 16 КБ (≈16000–19000
// байт)», «скачалось 32 КБ+ целиком — троттлинга на этом соединении нет».
const (
	throttleLo = 15000
	throttleHi = 21000
)

// TransferProbe запрашивает корень по HTTPS и считает, сколько доехало.
// Именованный возврат: отложенная функция проставляет длительность, а при
// возврате по значению правила бы уже скопированную структуру.
func TransferProbe(ctx context.Context, addr, sni string, timeout time.Duration) (t Transfer, err error) {
	t = Transfer{Host: sni, Addr: addr}
	start := time.Now()
	defer func() { t.DurationMS = time.Since(start).Milliseconds() }()

	d := net.Dialer{Timeout: timeout, Control: markControl}
	raw, derr := d.DialContext(ctx, "tcp", addr)
	if derr != nil {
		err = nil
		t.Verdict, t.Reason = "unreachable", "нет TCP: "+derr.Error()
		return t, nil
	}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(timeout))

	// Проверку сертификата снимаем осознанно: мы меряем ПРОХОДИМОСТЬ, а не
	// подлинность, и часто ходим по адресу в обход DNS.
	c := tls.Client(raw, &tls.Config{ServerName: sni, InsecureSkipVerify: true, MinVersion: tls.VersionTLS12})
	if herr := c.HandshakeContext(ctx); herr != nil {
		t.Verdict, t.Reason = "handshake_failed", "рукопожатие не прошло: "+herr.Error()
		return t, nil
	}

	req := "GET / HTTP/1.1\r\nHost: " + sni + "\r\nUser-Agent: z2k-detect/1\r\nAccept: */*\r\nConnection: close\r\n\r\n"
	if _, werr := c.Write([]byte(req)); werr != nil {
		t.Verdict, t.Reason = "truncated", "запрос не ушёл: "+werr.Error()
		return t, nil
	}

	buf := make([]byte, 32*1024)
	var raw_ []byte
	for {
		_ = c.SetReadDeadline(time.Now().Add(timeout))
		n, rerr := c.Read(buf)
		if n > 0 {
			t.TotalBytes += n
			if len(raw_) < 64*1024 {
				raw_ = append(raw_, buf[:n]...)
			}
		}
		if rerr != nil {
			if rerr == io.EOF {
				t.ClosedByPeer = true
			}
			break
		}
	}

	head, _, ok := splitHead(raw_)
	if !ok {
		t.Verdict, t.Reason = "truncated", fmt.Sprintf("заголовки не дочитаны, получено %d байт", t.TotalBytes)
		return t, nil
	}
	t.Status = statusOf(head)
	t.ContentLength = contentLength(head)
	t.Chunked = strings.Contains(strings.ToLower(head), "transfer-encoding: chunked")
	// Тело — это всё принятое минус заголовки с разделителем.
	t.BodyBytes = t.TotalBytes - len(head) - 4
	if t.BodyBytes < 0 {
		t.BodyBytes = 0
	}
	t.Location = locationOf(head)

	switch {
	case t.ContentLength > 0 && t.BodyBytes >= t.ContentLength:
		t.Verdict, t.Reason = "complete", fmt.Sprintf("доехало целиком: %d из %d байт тела", t.BodyBytes, t.ContentLength)
		t.demoteIfTooSmall()
	case t.ContentLength > 0:
		t.Verdict = "truncated"
		t.Reason = fmt.Sprintf("оборвано: %d из %d байт тела", t.BodyBytes, t.ContentLength)
		if t.TotalBytes >= throttleLo && t.TotalBytes <= throttleHi {
			t.Verdict = "throttled"
			t.Reason = fmt.Sprintf("поток встал на %d байт — это задокументированный порог ТСПУ 16–19 КБ; стратегией не лечится, нужен туннель", t.TotalBytes)
		}
	case t.Chunked || t.ContentLength == 0:
		// Длины нет — судим по закрытию, ради которого и стоял Connection: close.
		if t.ClosedByPeer {
			t.Verdict, t.Reason = "complete", fmt.Sprintf("длина не объявлена, сервер закрыл соединение сам: %d байт", t.TotalBytes)
			t.demoteIfTooSmall()
		} else {
			t.Verdict = "truncated"
			t.Reason = fmt.Sprintf("длина не объявлена и закрытия не было: %d байт", t.TotalBytes)
			if t.TotalBytes >= throttleLo && t.TotalBytes <= throttleHi {
				t.Verdict = "throttled"
				t.Reason = fmt.Sprintf("поток встал на %d байт — порог ТСПУ 16–19 КБ", t.TotalBytes)
			}
		}
	}
	return t, nil
}

// demoteIfTooSmall — «доехало целиком» на крошечном ответе НЕ доказывает
// отсутствия потолка. Чтобы упереться в порог 16–19 КБ, надо через него
// полезть; редирект в двести байт про потолок молчит. Объявлять по нему
// `complete` — та же неправда, что вердикт «режут по адресу» на молчащем
// контроле, и лечится так же: не утверждать, чего не мерили.
const informativeBytes = 32768

func (t *Transfer) demoteIfTooSmall() {
	if t.TotalBytes >= informativeBytes {
		return
	}
	was := t.TotalBytes
	t.Verdict = "inconclusive"
	t.Reason = fmt.Sprintf("ответ дочитан целиком, но всего %d байт — этого мало, чтобы упереться в потолок 16–19 КБ", was)
	if t.Location != "" {
		t.Reason += "; ответ был редиректом на " + t.Location + ", повтори по нему"
	}
}

func locationOf(head string) string {
	for _, ln := range strings.Split(head, "\r\n") {
		if strings.HasPrefix(strings.ToLower(ln), "location:") {
			return strings.TrimSpace(ln[len("location:"):])
		}
	}
	return ""
}

func splitHead(b []byte) (head string, body []byte, ok bool) {
	i := strings.Index(string(b), "\r\n\r\n")
	if i < 0 {
		return "", nil, false
	}
	return string(b[:i]), b[i+4:], true
}

func statusOf(head string) int {
	f := strings.Fields(head)
	if len(f) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(f[1])
	return n
}

func contentLength(head string) int {
	for _, ln := range strings.Split(head, "\r\n") {
		if strings.HasPrefix(strings.ToLower(ln), "content-length:") {
			n, err := strconv.Atoi(strings.TrimSpace(ln[len("content-length:"):]))
			if err == nil {
				return n
			}
		}
	}
	return 0
}
