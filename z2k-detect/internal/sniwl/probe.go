package sniwl

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"time"
)

// Умолчания пробы. Значения из оригинала (dpi-detector/config.yml) там, где
// они часть ТРИГГЕРА, и наши там, где они про домашнюю линию и слабый роутер.
const (
	// DefaultChunks — сколько HEAD-запросов гоним по одному соединению.
	// 10 × 4000 = 36 КБ аплинка, детект-окно 16–20 КБ пересекается на 4-м.
	DefaultChunks = 10
	// DefaultChunkSize — байт мусора в X-Pad на один запрос. Именно 4000,
	// не 4096: с 4096 накопление сдвигается и окно ловится другим куском.
	DefaultChunkSize = 4000
	// DefaultChunkDelay — пауза после каждого запроса. НЕ «вежливость»:
	// пауза задаёт окно пересборки у коробки и входит в триггер.
	DefaultChunkDelay = 50 * time.Millisecond
	// DefaultConnectTimeout — 8 с оригинала подняты до 10: на нагруженном
	// канале Keenetic TCP+TLS в 8 с не всегда укладываются, и получался
	// ложный «бан» на живом адресе.
	DefaultConnectTimeout = 10 * time.Second
	// DefaultReadTimeout — потолок адаптивного таймаута, как в оригинале.
	DefaultReadTimeout = 12 * time.Second
	// DefaultRTTFloor / DefaultRTTFactor — пол и множитель адаптива. У них
	// max(rtt*3, 1.5s): при RTT 300–400 мс это 1.2 с, упирается в пол 1.5 с
	// и штампует ложные обрывы на первом же чихе линии. Наши 4× и 3 с
	// оставляют запас, не трогая потолок.
	DefaultRTTFloor  = 3 * time.Second
	DefaultRTTFactor = 4.0
	// DefaultBlockMinKB — нижняя граница детект-окна. Замеренный обрыв
	// 15994 байт приходится на 4-й кусок, то есть с запасом внутри.
	DefaultBlockMinKB = 12

	// DefaultBaselineSNI — имя контрольного плеча. Нейтральное имя нужно
	// потому, что цель обычно ещё и заблокирована ПО ИМЕНИ (она из РКН),
	// и проба её собственным именем мерила бы совсем другую блокировку.
	DefaultBaselineSNI = "example.com"

	// randomPoolSize — пул мусора на процесс. Аллокаций на пробу нет,
	// окно берётся слайсом.
	randomPoolSize = 100000

	userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
)

// randomPool — [A-Za-z0-9] один раз на процесс. math/rand здесь достаточно:
// это набивка заголовка, а не ключ.
var randomPool = func() []byte {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, randomPoolSize)
	for i := range b {
		b[i] = alphabet[rand.Intn(len(alphabet))]
	}
	return b
}()

// Dialer отдаёт соединение, ГОТОВОЕ к отправке HTTP-запросов: в бою это
// TCP + TLS-рукопожатие с нужным именем, в тестах — обычный сокет к
// поддельному серверу. Инъекция здесь и только здесь: всё остальное в пакете
// чистое и на раннере проверяется без сети и без привилегий.
type Dialer func(ctx context.Context, addr, sni string) (net.Conn, error)

// ProbeConfig — ручки одной пробы.
type ProbeConfig struct {
	Chunks         int
	ChunkSize      int
	ChunkDelay     time.Duration
	ConnectTimeout time.Duration
	ReadTimeout    time.Duration
	RTTFloor       time.Duration
	RTTFactor      float64
	BlockMinKB     int
	// Dial — nil означает боевой диалер: SO_MARK + TLS.
	Dial Dialer
}

// WithDefaults заполняет незаданное. Возвращает копию — конфиг у вызывающего
// не мутируется.
func (c ProbeConfig) WithDefaults() ProbeConfig {
	if c.Chunks <= 0 {
		c.Chunks = DefaultChunks
	}
	if c.ChunkSize <= 0 {
		c.ChunkSize = DefaultChunkSize
	}
	if c.ChunkDelay < 0 {
		c.ChunkDelay = DefaultChunkDelay
	}
	if c.ChunkDelay == 0 {
		c.ChunkDelay = DefaultChunkDelay
	}
	if c.ConnectTimeout <= 0 {
		c.ConnectTimeout = DefaultConnectTimeout
	}
	if c.ReadTimeout <= 0 {
		c.ReadTimeout = DefaultReadTimeout
	}
	if c.RTTFloor <= 0 {
		c.RTTFloor = DefaultRTTFloor
	}
	if c.RTTFactor <= 0 {
		c.RTTFactor = DefaultRTTFactor
	}
	if c.BlockMinKB <= 0 {
		c.BlockMinKB = DefaultBlockMinKB
	}
	if c.Dial == nil {
		c.Dial = DialTLSMarked
	}
	return c
}

// MinDetectChunk — с какого куска обрыв считается работой коробки.
//
// Формула оригинала: max(1, int(BlockMinKB*1024/ChunkSize)) — усечение, не
// округление. При 12 КБ и кусках по 4000 это 3, то есть фактический порог по
// мусору 12000 байт, чуть ниже заявленных 12 КиБ. Расхождение сохранено
// намеренно: пороги подобраны под него.
func MinDetectChunk(blockMinKB, chunkSize int) int {
	if chunkSize <= 0 {
		return 1
	}
	n := blockMinKB * 1024 / chunkSize
	if n < 1 {
		return 1
	}
	return n
}

// ProbeResult — исход одной пробы одного имени.
type ProbeResult struct {
	SNI string `json:"sni"`
	// Alive — соединение поднялось (TCP+TLS прошли). Это НЕ «имя пробивает»:
	// типичный DETECTED — это Alive=true.
	Alive bool `json:"alive"`
	// Chunk — номер куска, на котором оборвалось; -1, если прошли все.
	Chunk  int    `json:"chunk"`
	Status Status `json:"status"`
	// UplinkBytes — сколько байт мы успели отправить к моменту обрыва.
	// Это и есть измеряемая величина: триггер у коробки на АПЛИНК.
	UplinkBytes int           `json:"uplink_bytes"`
	RTT         time.Duration `json:"rtt"`
	Detail      string        `json:"detail,omitempty"`
	DurationMS  int64         `json:"duration_ms"`
}

// KB — накопленный аплинк в килобайтах на момент обрыва, для человека.
func (p ProbeResult) KB() int { return p.UplinkBytes / 1024 }

// Probe гонит одну пробу одного имени по адресу addr (host:port).
//
// hint — RTT, измеренный ранее по этому же адресу; 0 означает «мерить самим»
// (тогда первые два куска идут с плоским потолком, и адаптив включается с
// третьего, ровно как в оригинале).
func Probe(ctx context.Context, addr, sni string, cfg ProbeConfig, hint time.Duration) ProbeResult {
	cfg = cfg.WithDefaults()
	start := time.Now()

	dctx, cancel := context.WithTimeout(ctx, cfg.ConnectTimeout)
	defer cancel()
	conn, err := cfg.Dial(dctx, addr, sni)
	if err != nil {
		// Не дозвонились или не сошлось рукопожатие — про объём это не
		// говорит ничего, и вердиктом о блокировке быть не может.
		return ProbeResult{
			SNI:        sni,
			Chunk:      -1,
			Status:     StatusFail,
			Detail:     "соединение не поднялось: " + err.Error(),
			DurationMS: time.Since(start).Milliseconds(),
		}
	}
	defer conn.Close()

	// Host для беспэдового режима «без SNI»: httpx в оригинале подставляет
	// туда сам адрес, и коробка видит ровно это.
	host := sni
	if host == "" {
		host = addr
	}
	out := runChunks(ctx, conn, host, cfg, hint)
	out.SNI = sni
	out.Alive = true
	out.DurationMS = time.Since(start).Milliseconds()
	return out
}

// runChunks — ядро пробы: N запросов по одному соединению, мусор в аплинк.
//
// Соединение своё, без net/http.Transport, и это принципиально: Transport сам
// переоткрывает сокет и сам ПОВТОРЯЕТ идемпотентный запрос (HEAD идемпотентен),
// когда ошибка случилась на переиспользованном соединении до первых байт
// ответа. То есть он молча съел бы ровно ту улику, за которой мы пришли.
func runChunks(ctx context.Context, conn net.Conn, host string, cfg ProbeConfig, hint time.Duration) ProbeResult {
	cfg = cfg.WithDefaults()
	minDetect := MinDetectChunk(cfg.BlockMinKB, cfg.ChunkSize)
	res := ProbeResult{Chunk: -1, Alive: true}

	br := bufio.NewReader(conn)
	// HEAD: без этого http.ReadResponse полезет читать тело по Content-Length
	// и проба встанет на каждом шаге.
	headReq := &http.Request{Method: http.MethodHead}

	dyn := time.Duration(0)
	if hint > 0 {
		dyn = adaptiveTimeout(hint, cfg)
		res.RTT = hint
	}
	var e0, e1 time.Duration

	for i := 0; i < cfg.Chunks; i++ {
		if err := ctx.Err(); err != nil {
			res.Status = StatusFail
			res.Detail = "отменено: " + err.Error()
			res.Chunk = i
			return res
		}
		to := cfg.ReadTimeout
		if dyn > 0 {
			to = dyn
		}
		req := buildRequest(host, i, cfg)
		step := time.Now()
		_ = conn.SetDeadline(step.Add(to))
		n, werr := conn.Write(req)
		res.UplinkBytes += n
		if werr != nil {
			return finish(res, i, minDetect, cfg, werr)
		}
		resp, rerr := http.ReadResponse(br, headReq)
		if rerr != nil {
			return finish(res, i, minDetect, cfg, rerr)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		elapsed := time.Since(step)
		if resp.Close {
			// Сервер сам отказался от keep-alive. Это его политика, а не
			// коробка: без keep-alive накопить аплинк нечем, и вердикт про
			// блокировку по этому адресу не строится вовсе.
			res.Chunk = i
			res.Status = StatusFail
			res.Detail = fmt.Sprintf("сервер закрыл keep-alive на куске %d — по этому адресу проба неприменима", i)
			return res
		}
		switch i {
		case 0:
			e0 = elapsed
			if hint <= 0 {
				res.RTT = elapsed
			}
		case 1:
			e1 = elapsed
			if hint <= 0 {
				base := e0
				if e1 > base {
					base = e1
				}
				dyn = adaptiveTimeout(base, cfg)
			}
		}
		if cfg.ChunkDelay > 0 {
			t := time.NewTimer(cfg.ChunkDelay)
			select {
			case <-ctx.Done():
				t.Stop()
				res.Chunk = i
				res.Status = StatusFail
				res.Detail = "отменено: " + ctx.Err().Error()
				return res
			case <-t.C:
			}
		}
	}
	res.Status = StatusOK
	return res
}

// finish применяет правило вердикта. Различие делает НОМЕР КУСКА, а не тип
// ошибки: у нас соединение своё, поэтому смерть соединения приходит как
// ошибка записи или чтения — переподключаться, как это делал httpcore, нам
// не нужно и не надо.
func finish(res ProbeResult, i, minDetect int, cfg ProbeConfig, err error) ProbeResult {
	res.Chunk = i
	res.Detail = describeErr(err)
	switch {
	case i == 0:
		// Нулевой кусок идёт БЕЗ мусора — это проба живости. Обрыв на нём
		// не про объём: адрес либо мёртв, либо нас уже режут/лимитируют.
		res.Status = StatusFail
	case i < minDetect:
		// До детект-окна не дошли: шум линии или сервера, не коробка.
		res.Status = StatusBreak
		res.Detail = fmt.Sprintf("%s (обрыв на %d КБ — раньше детект-окна)", res.Detail, res.UplinkBytes/1024)
	default:
		res.Status = StatusDetected
		res.Detail = fmt.Sprintf("%s (обрыв на %d байт аплинка, кусок %d)", res.Detail, res.UplinkBytes, i)
	}
	return res
}

func describeErr(err error) string {
	if err == nil {
		return ""
	}
	var ne net.Error
	switch {
	case errors.As(err, &ne) && ne.Timeout():
		return "таймаут"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return "соединение закрыто"
	}
	return err.Error()
}

func adaptiveTimeout(rtt time.Duration, cfg ProbeConfig) time.Duration {
	d := time.Duration(float64(rtt) * cfg.RTTFactor)
	if d < cfg.RTTFloor {
		d = cfg.RTTFloor
	}
	if d > cfg.ReadTimeout {
		d = cfg.ReadTimeout
	}
	return d
}

// buildRequest собирает один HEAD. Мусор идёт со ВТОРОГО куска: первый — это
// замер RTT и проверка живости, и пэд на нём сбил бы обе.
func buildRequest(host string, i int, cfg ProbeConfig) []byte {
	var b []byte
	b = append(b, "HEAD / HTTP/1.1\r\nHost: "...)
	b = append(b, host...)
	b = append(b, "\r\nUser-Agent: "...)
	b = append(b, userAgent...)
	b = append(b, "\r\nConnection: keep-alive\r\n"...)
	if i >= 1 {
		b = append(b, "X-Pad: "...)
		b = append(b, garbage(cfg.ChunkSize)...)
		b = append(b, "\r\n"...)
	}
	b = append(b, "\r\n"...)
	return b
}

// garbage отдаёт окно из общего пула. Копии нет — байты уходят в append выше.
func garbage(n int) []byte {
	if n <= 0 {
		return nil
	}
	if n >= len(randomPool) {
		return randomPool
	}
	off := rand.Intn(len(randomPool) - n)
	return randomPool[off : off+n]
}

// DialTLSMarked — боевой диалер: SO_MARK + TLS с заданным именем.
//
// Проверку сертификата снимаем осознанно: мы меряем ПРОХОДИМОСТЬ, а не
// подлинность, и по построению ходим чужим именем на чужой адрес.
// Пустое имя даёт ClientHello БЕЗ расширения SNI вообще — это отдельный,
// четвёртый режим пробы, а не «SNI равен адресу».
func DialTLSMarked(ctx context.Context, addr, sni string) (net.Conn, error) {
	d := net.Dialer{Control: markControl}
	raw, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	if dl, ok := ctx.Deadline(); ok {
		_ = raw.SetDeadline(dl)
	}
	c := tls.Client(raw, &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS12,
	})
	if err := c.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	// Дедлайн подключения снимаем: дальше каждый кусок ставит свой.
	_ = raw.SetDeadline(time.Time{})
	return c, nil
}
