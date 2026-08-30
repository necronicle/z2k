package sniwl

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

// fakeBox — поддельная коробка DPI на net.Pipe.
//
// Настоящая коробка ведёт себя так: отвечает, пока накопленный АПЛИНК меньше
// порога, а после порога перестаёт пропускать поток и просто молчит до
// таймаута. Сокет не закрывается — именно поэтому обрыв виден как таймаут
// чтения, а не как EOF, и именно поэтому старый пробер записывал его в
// «неубедительно».
//
// Пары net.Pipe хватает целиком: ни листенера, ни порта, ни привилегий — тесты
// проходят на CI-раннере, где internal/prober отключён как раз из-за них.
type fakeBox struct {
	// cutAt — молчим, как только СЕРВЕР прочитал столько байт запросов.
	cutAt int
	// closeHeader — отвечать «Connection: close», то есть отказываться от
	// keep-alive. Политика сервера, а не коробка.
	closeHeader bool
	// requests — сколько запросов сервер успел прочитать.
	requests int
	// read — сколько байт аплинка сервер увидел.
	read int
}

func (b *fakeBox) dialer(t *testing.T) Dialer {
	t.Helper()
	return func(ctx context.Context, addr, sni string) (net.Conn, error) {
		client, server := net.Pipe()
		go b.serve(server)
		t.Cleanup(func() { _ = client.Close() })
		return client, nil
	}
}

func (b *fakeBox) serve(c net.Conn) {
	defer c.Close()
	cr := &countingReader{r: c}
	br := bufio.NewReader(cr)
	for {
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}
		_ = req.Body.Close()
		b.requests++
		b.read = cr.n
		if cr.n >= b.cutAt {
			// Молчим, но сокет держим открытым и продолжаем вычитывать:
			// ровно так выглядит вставший поток с той стороны.
			_, _ = io.Copy(io.Discard, cr)
			return
		}
		resp := "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
		if b.closeHeader {
			resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		}
		if _, err := c.Write([]byte(resp)); err != nil {
			return
		}
	}
}

type countingReader struct {
	r io.Reader
	n int
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

// testProbeCfg — та же механика, но в масштабе теста: куски по 1000 байт и
// порог 3 КБ дают тот же MinDetectChunk=3, что и боевые 4000/12 КБ.
func testProbeCfg(d Dialer) ProbeConfig {
	return ProbeConfig{
		Chunks:         8,
		ChunkSize:      1000,
		ChunkDelay:     time.Millisecond,
		ConnectTimeout: time.Second,
		ReadTimeout:    250 * time.Millisecond,
		RTTFloor:       80 * time.Millisecond,
		RTTFactor:      4,
		BlockMinKB:     3,
		Dial:           d,
	}
}

func TestMinDetectChunk(t *testing.T) {
	cases := []struct {
		kb, size, want int
	}{
		// Боевая пара: 12*1024/4000 = 3.072 → усечение до 3, то есть
		// фактический порог 12000 Б, чуть ниже заявленных 12 КиБ.
		// Расхождение оригинала сохранено намеренно.
		{12, 4000, 3},
		{3, 1000, 3},
		{16, 4000, 4},
		{1, 4000, 1}, // не ниже единицы
		{0, 4000, 1},
		{12, 0, 1}, // деления на ноль быть не должно
	}
	for _, c := range cases {
		if got := MinDetectChunk(c.kb, c.size); got != c.want {
			t.Errorf("MinDetectChunk(%d, %d) = %d, ждали %d", c.kb, c.size, got, c.want)
		}
	}
}

func TestProbeAllChunksPass(t *testing.T) {
	box := &fakeBox{cutAt: 1 << 30}
	res := Probe(context.Background(), "box:443", "disk.rzd.ru", testProbeCfg(box.dialer(t)), 0)
	if res.Status != StatusOK {
		t.Fatalf("статус %s (%s), ждали OK", res.Status, res.Detail)
	}
	if res.Chunk != -1 {
		t.Errorf("Chunk=%d, ждали -1 — обрыва не было", res.Chunk)
	}
	if !res.Alive {
		t.Error("Alive=false при прошедшей пробе")
	}
	if res.SNI != "disk.rzd.ru" {
		t.Errorf("SNI=%q не сохранён в результате", res.SNI)
	}
	// Восемь кусков: один без пэда и семь по 1000 байт мусора.
	if res.UplinkBytes < 7000 {
		t.Errorf("аплинк %d байт — мусор не ушёл наружу", res.UplinkBytes)
	}
}

func TestProbeDetectsCutoffInsideWindow(t *testing.T) {
	// Порог 4000 байт: сервер отвечает на куски 0..3 и замолкает на 4-м —
	// ровно как замеренная линия владельца, вставшая на 15994 байтах.
	box := &fakeBox{cutAt: 4000}
	res := Probe(context.Background(), "box:443", "example.com", testProbeCfg(box.dialer(t)), 0)
	if res.Status != StatusDetected {
		t.Fatalf("статус %s (%s), ждали DETECTED", res.Status, res.Detail)
	}
	if res.Chunk < 3 {
		t.Errorf("обрыв на куске %d — это раньше детект-окна", res.Chunk)
	}
	if res.UplinkBytes < 3000 {
		t.Errorf("аплинк на обрыве %d байт — слишком мало для вердикта", res.UplinkBytes)
	}
	if !res.Alive {
		t.Error("Alive=false: соединение поднималось, DETECTED всегда живой")
	}
	if !strings.Contains(res.Detail, "аплинка") {
		t.Errorf("в детали нет накопленного аплинка: %q", res.Detail)
	}
}

func TestProbeDetectsExactlyAtBoundary(t *testing.T) {
	// Обрыв ровно на MinDetectChunk. Граница включающая: третий кусок уже
	// вердикт, а не шум.
	box := &fakeBox{cutAt: 3000}
	res := Probe(context.Background(), "box:443", "example.com", testProbeCfg(box.dialer(t)), 0)
	if res.Chunk != 3 {
		t.Fatalf("обрыв на куске %d, ждали 3 (%s)", res.Chunk, res.Detail)
	}
	if res.Status != StatusDetected {
		t.Fatalf("статус %s, ждали DETECTED — граница должна быть включающей", res.Status)
	}
}

func TestProbeBreakBeforeWindowIsNotDetection(t *testing.T) {
	// Обрыв на первом же куске с мусором. До детект-окна не дошли, значит
	// это шум линии или сервера — записать его в блокировку значит потом
	// объявить «сеть режет» по любому чиху канала.
	box := &fakeBox{cutAt: 1000}
	res := Probe(context.Background(), "box:443", "example.com", testProbeCfg(box.dialer(t)), 0)
	if res.Chunk != 1 {
		t.Fatalf("обрыв на куске %d, ждали 1 (%s)", res.Chunk, res.Detail)
	}
	if res.Status != StatusBreak {
		t.Fatalf("статус %s, ждали BREAK", res.Status)
	}
	if res.Status.Valid() {
		t.Error("BREAK не должен считаться измерением коробки")
	}
}

func TestProbeFailsOnChunkZero(t *testing.T) {
	// Нулевой кусок идёт БЕЗ мусора — это проба живости. Обрыв на нём про
	// объём не говорит ничего и служит детектором бана/рейт-лимита.
	box := &fakeBox{cutAt: 0}
	res := Probe(context.Background(), "box:443", "example.com", testProbeCfg(box.dialer(t)), 0)
	if res.Chunk != 0 {
		t.Fatalf("обрыв на куске %d, ждали 0", res.Chunk)
	}
	if res.Status != StatusFail {
		t.Fatalf("статус %s, ждали FAIL", res.Status)
	}
}

func TestProbeFailsWhenDialFails(t *testing.T) {
	d := func(ctx context.Context, addr, sni string) (net.Conn, error) {
		return nil, errors.New("connection refused")
	}
	res := Probe(context.Background(), "box:443", "example.com", testProbeCfg(d), 0)
	if res.Status != StatusFail {
		t.Fatalf("статус %s, ждали FAIL", res.Status)
	}
	if res.Alive {
		t.Error("Alive=true, хотя соединение не поднялось")
	}
	if res.Chunk != -1 {
		t.Errorf("Chunk=%d, ждали -1 — кусков не было вовсе", res.Chunk)
	}
}

func TestProbeFailsWhenServerRefusesKeepAlive(t *testing.T) {
	// Без keep-alive накопить аплинк нечем: вопрос про объём по такому
	// адресу не задаётся, и выдавать за вердикт это нельзя.
	box := &fakeBox{cutAt: 1 << 30, closeHeader: true}
	res := Probe(context.Background(), "box:443", "example.com", testProbeCfg(box.dialer(t)), 0)
	if res.Status != StatusFail {
		t.Fatalf("статус %s (%s), ждали FAIL", res.Status, res.Detail)
	}
	if !strings.Contains(res.Detail, "keep-alive") {
		t.Errorf("деталь не называет причину: %q", res.Detail)
	}
}

func TestProbeHonoursContextCancel(t *testing.T) {
	box := &fakeBox{cutAt: 1 << 30}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res := Probe(ctx, "box:443", "example.com", testProbeCfg(box.dialer(t)), 0)
	if res.Status != StatusFail {
		t.Fatalf("статус %s, ждали FAIL при отменённом контексте", res.Status)
	}
}

func TestBuildRequestPadsEveryChunkButTheFirst(t *testing.T) {
	cfg := ProbeConfig{ChunkSize: 1000}.WithDefaults()
	first := buildRequest("disk.rzd.ru", 0, cfg)
	if bytes.Contains(first, []byte("X-Pad:")) {
		t.Error("нулевой кусок с мусором — он должен мерить RTT и живость")
	}
	if !bytes.Contains(first, []byte("Host: disk.rzd.ru\r\n")) {
		t.Errorf("Host не подставлен: %q", first[:60])
	}
	if !bytes.HasPrefix(first, []byte("HEAD / HTTP/1.1\r\n")) {
		t.Errorf("метод не HEAD: %q", first[:20])
	}
	if !bytes.Contains(first, []byte("Connection: keep-alive\r\n")) {
		t.Error("нет keep-alive — накапливать аплинк будет негде")
	}
	if !bytes.HasSuffix(first, []byte("\r\n\r\n")) {
		t.Error("запрос не завершён пустой строкой")
	}

	second := buildRequest("disk.rzd.ru", 1, cfg)
	if !bytes.Contains(second, []byte("X-Pad: ")) {
		t.Fatal("на первом же куске после нулевого мусора нет")
	}
	if got := len(second) - len(first); got != 1009 {
		t.Errorf("прирост от мусора %d байт, ждали 1009 (X-Pad: + 1000 + CRLF)", got)
	}
}

func TestGarbageWindowStaysInsidePool(t *testing.T) {
	for i := 0; i < 200; i++ {
		g := garbage(4000)
		if len(g) != 4000 {
			t.Fatalf("окно мусора %d байт, ждали 4000", len(g))
		}
	}
	if got := len(garbage(randomPoolSize * 2)); got != randomPoolSize {
		t.Errorf("запрос больше пула отдал %d, ждали %d", got, randomPoolSize)
	}
	if garbage(0) != nil {
		t.Error("нулевое окно должно быть nil")
	}
}

func TestAdaptiveTimeoutBounds(t *testing.T) {
	cfg := ProbeConfig{}.WithDefaults()
	// Пол: короткий RTT не должен давать таймаут, который сорвётся от
	// первого же чиха линии. У оригинала пол 1.5 с давал ложные обрывы.
	if got := adaptiveTimeout(10*time.Millisecond, cfg); got != DefaultRTTFloor {
		t.Errorf("при RTT 10мс таймаут %v, ждали пол %v", got, DefaultRTTFloor)
	}
	// Потолок.
	if got := adaptiveTimeout(30*time.Second, cfg); got != DefaultReadTimeout {
		t.Errorf("при RTT 30с таймаут %v, ждали потолок %v", got, DefaultReadTimeout)
	}
	// Середина: rtt * 4.
	if got := adaptiveTimeout(2*time.Second, cfg); got != 8*time.Second {
		t.Errorf("при RTT 2с таймаут %v, ждали 8с", got)
	}
}
