// Package tcp16 — проба на блокировку по объёму соединения («16-20 КБ»).
//
// Класс блокировки: коробка пропускает рукопожатие и первые килобайты, а затем
// рвёт соединение, набравшее примерно 12-34 КБ. Ротацией плеч он не лечится —
// несущая часть обхода не разрез, а ИМЯ в фейковом ClientHello.
//
// Процедура повторяет runnin4ik/dpi-detector (core/tcp16_scanner.py, MIT):
// по ОДНОМУ keep-alive соединению шлётся десять HEAD-запросов, начиная со
// второго — с мусорным заголовком X-Pad на 4000 байт. Накопленный объём растёт
// 4, 8, 12 … 40 КБ. Смерть соединения на чанке, где объём уже перевалил за
// порог, и есть вердикт; смерть раньше порога — обычный сетевой сбой, не он.
//
// Почему проба, а не наблюдение за трафиком человека. Наблюдение отвечает на
// вопрос «этот хост сейчас режут?» и ошибается: горизонт видимости движка
// меряется в пакетах, и здоровая крупная загрузка выглядит как обрыв. Проба
// отвечает на другой вопрос — «есть ли этот блок на ЭТОЙ ЛИНИИ» — на
// контролируемой мишени и контролируемым объёмом, за секунды и не трогая
// пользовательский трафик вовсе.
package tcp16

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"math/rand"
	"net"
	"strings"
	"time"
)

const (
	// Размер мусорного заголовка и число запросов — как в первоисточнике.
	ChunkSize   = 4000
	ChunkCount  = 10
	// Порог: до 12 КБ обрыв не считается этим классом. Ниже него рвут по
	// множеству обычных причин, и вердикт был бы шумом.
	MinDetectKB = 12

	connectTimeout = 5 * time.Second
	readTimeout    = 6 * time.Second
)

// Target — мишень пробы: адрес, порт и AS, к которой он принадлежит.
type Target struct {
	ID       string
	ASN      string
	Provider string
	IP       string
	Port     int
}

// Result — исход одной пробы.
type Result struct {
	Target    Target
	SNI       string
	Alive     bool   // сервер вообще ответил на первый запрос
	Detected  bool   // соединение умерло за порогом — это наш класс
	DiedAtKB  int    // на каком накопленном объёме умерло
	Err       string // человеческая причина, если проба не состоялась
	RTT       time.Duration
}

var padPool = func() string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, ChunkSize*2)
	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	for i := range b {
		b[i] = alphabet[r.Intn(len(alphabet))]
	}
	return string(b)
}()

// Probe гоняет пробу по одной мишени. sni пустой — идём без SNI (по адресу).
func Probe(ctx context.Context, t Target, sni string) Result {
	res := Result{Target: t, SNI: sni}

	d := net.Dialer{Timeout: connectTimeout}
	addr := net.JoinHostPort(t.IP, fmt.Sprint(t.Port))
	start := time.Now()
	raw, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		res.Err = "нет TCP: " + errShort(err)
		return res
	}
	defer raw.Close()

	var conn net.Conn = raw
	if t.Port != 80 {
		// Сертификат не проверяем: идём по адресу, имя подставляем сами —
		// нас интересует реакция коробки, а не подлинность сервера.
		tc := tls.Client(raw, &tls.Config{ServerName: sni, InsecureSkipVerify: true})
		if err := tc.HandshakeContext(ctx); err != nil {
			res.Err = "нет TLS: " + errShort(err)
			return res
		}
		conn = tc
	}
	res.RTT = time.Since(start)

	host := t.IP
	if sni != "" {
		host = sni
	}
	br := bufio.NewReader(conn)

	for i := 0; i < ChunkCount; i++ {
		var sb strings.Builder
		sb.WriteString("HEAD / HTTP/1.1\r\nHost: ")
		sb.WriteString(host)
		sb.WriteString("\r\nUser-Agent: Mozilla/5.0\r\nConnection: keep-alive\r\n")
		if i > 0 {
			// Мусор в заголовке — единственный способ накачать соединение
			// исходящим объёмом, не завися от того, что отдаёт сервер.
			off := rand.Intn(len(padPool) - ChunkSize)
			sb.WriteString("X-Pad: ")
			sb.WriteString(padPool[off : off+ChunkSize])
			sb.WriteString("\r\n")
		}
		sb.WriteString("\r\n")

		sentKB := i * ChunkSize / 1024
		conn.SetDeadline(time.Now().Add(readTimeout))
		if _, err := conn.Write([]byte(sb.String())); err != nil {
			return finish(res, i, sentKB, err)
		}
		if err := drainHead(br); err != nil {
			return finish(res, i, sentKB, err)
		}
		if i == 0 {
			res.Alive = true
		}
		// Пауза как в первоисточнике: без неё коробка иногда видит поток
		// иначе, чем видит его браузер.
		time.Sleep(50 * time.Millisecond)
	}
	return res
}

// finish превращает обрыв на чанке i в вердикт с учётом порога.
func finish(res Result, i, sentKB int, err error) Result {
	res.Err = errShort(err)
	res.DiedAtKB = sentKB
	if i == 0 {
		// Умерли на первом же запросе — сервер недоступен, а не блок.
		return res
	}
	res.Alive = true
	if sentKB >= MinDetectKB {
		res.Detected = true
	}
	return res
}

// drainHead читает ответ на HEAD: заголовки до пустой строки, тела нет.
func drainHead(br *bufio.Reader) error {
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return err
		}
		if line == "\r\n" || line == "\n" {
			return nil
		}
	}
}

func errShort(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i >= 0 && len(s)-i < 40 {
		s = s[i+2:]
	}
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}
