// Package tcp16 — проба на блокировку по объёму соединения («16-20 КБ»).
//
// Класс блокировки: коробка пропускает рукопожатие и первые килобайты, а затем
// рвёт соединение, набравшее примерно 12-34 КБ. Ротацией плеч он не лечится —
// несущая часть обхода не разрез, а ИМЯ в фейковом ClientHello.
//
// Процедура: по ОДНОМУ keep-alive соединению шлётся десять HEAD-запросов,
// начиная со второго — с мусорным заголовком X-Pad на 4000 байт. Накопленный
// объём растёт 4, 8, 12 … 40 КБ. Смерть соединения на чанке, где объём уже
// перевалил за порог, и есть вердикт; смерть раньше порога — обычный сетевой
// сбой, не он.
//
// Накачиваем ИСХОДЯЩИМ объёмом, а не скачиванием: так объём задаём мы сами и
// не зависим от того, что и как отдаёт мишень.
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
	// ПАРАМЕТРЫ ПРОБЫ. Каждое число — из замера на боевом роутере 31.08.2026,
	// менять только вместе с новым замером.
	//
	// Накачка объёмом: десять запросов по одному соединению, со второго — с
	// мусорным заголовком на 4000 байт. Накопленный объём растёт 4, 8, 12 … 40
	// КБ и покрывает весь наблюдавшийся разброс обрыва (12-34 КБ).
	ChunkSize  = 4000
	ChunkCount = 10

	// Ниже этого объёма обрыв нашим классом не считается: до 12 КБ соединения
	// рвутся по десятку обычных причин, и вердикт был бы шумом.
	MinDetectKB = 12

	connectTimeout   = 8 * time.Second
	handshakeTimeout = 8 * time.Second
	chunkDelay       = 50 * time.Millisecond

	// ОЖИДАНИЕ ОТВЕТА СЧИТАЕТСЯ ОТ ИЗМЕРЕННОГО RTT, а не берётся с потолка.
	//
	// Живой ответ приходит за один RTT; «нет ответа» — это неподходящее имя,
	// на котором коробка просто молчит. С фиксированным потолком каждый
	// мимо-кандидат стоил полные шесть секунд, и полный подбор на роутере не
	// уложился в десять минут. Втрое от RTT хватает с запасом, нижняя граница
	// защищает от слишком оптимистичного замера на первом пакете, верхняя —
	// от линии, где RTT сам по себе огромен.
	readTimeoutMin = 1500 * time.Millisecond
	readTimeoutMax = 12 * time.Second
)

// Target — мишень пробы: адрес, порт и AS, к которой он принадлежит.
type Target struct {
	ID       string
	ASN      string
	Provider string
	IP       string
	Port     int
	// SNI — имя, которое надо предъявить этой мишени. Пусто у большинства:
	// туда ходим по адресу. Непустое у тех, кто без имени отвечает не тем
	// сервисом — у эталонного dpi-detector таких семь, все Fastly. Без имени
	// они отвечают чужой заглушкой, и обрыв по объёму на них не наступает
	// никогда: мы меряли не то, что они меряют.
	SNI string
}

// Result — исход одной пробы.
type Result struct {
	Target   Target
	SNI      string
	Alive    bool   // сервер вообще ответил на первый запрос
	Detected bool   // соединение умерло за порогом — это наш класс
	DiedAtKB int    // на каком накопленном объёме умерло
	Err      string // человеческая причина, если проба не состоялась
	RTT      time.Duration
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
		//
		// Дедлайн обязателен. Коробка на неподходящем имени не отвечает вовсе,
		// и рукопожатие висит без ограничения по времени: перебор кандидатов
		// вставал намертво на первом же таком имени и до рабочего не доходил.
		// Замер 30.08.2026: hcaptcha.com к Hetzner — тишина, 300.ya.ru — проходит.
		raw.SetDeadline(time.Now().Add(handshakeTimeout))
		tc := tls.Client(raw, &tls.Config{ServerName: sni, InsecureSkipVerify: true})
		if err := tc.HandshakeContext(ctx); err != nil {
			res.Err = "нет TLS: " + errShort(err)
			return res
		}
		conn = tc
	}
	raw.SetDeadline(time.Time{})
	res.RTT = time.Since(start)

	host := t.IP
	if sni != "" {
		host = sni
	}
	br := bufio.NewReader(conn)

	// Пока RTT не измерен — ждём по потолку; после первого ответа сужаем.
	readTimeout := readTimeoutMax

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
		reqStart := time.Now()
		if _, err := conn.Write([]byte(sb.String())); err != nil {
			return finish(res, i, sentKB, err)
		}
		if err := drainHead(br); err != nil {
			return finish(res, i, sentKB, err)
		}
		if i == 0 {
			res.Alive = true
			// RTT известен — дальше ждём втрое дольше него, но в разумных
			// границах. Живой ответ приходит за один RTT, а «нет ответа»
			// распознаётся втрое быстрее прежнего.
			rtt := time.Since(reqStart)
			readTimeout = rtt * 3
			if readTimeout < readTimeoutMin {
				readTimeout = readTimeoutMin
			}
			if readTimeout > readTimeoutMax {
				readTimeout = readTimeoutMax
			}
		}
		// Пауза между запросами: без неё десять запросов уходят одной
		// очередью, и коробка видит поток иначе, чем видит его браузер, —
		// вердикт становится плавающим.
		time.Sleep(chunkDelay)
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
