// Package tunshare — один TUN на весь срок жизни демона, сменяемые транспорты.
//
// wireguard-go закрывает TUN в device.Close(), а его читающая горутина
// блокируется в read(2) и проснётся только на следующем пакете — то есть
// старый транспорт утащил бы каждый второй пакет у нового. Поэтому TUN
// читает ровно одна горутина здесь, а транспорты получают Handle: Read
// отдаёт пакеты из общего канала и сразу возвращает ошибку после Close,
// Write идёт прямо в устройство (у wireguard-go он под мьютексом).
package tunshare

import (
	"fmt"
	"os"
	"sync"

	"golang.zx2c4.com/wireguard/tun"
)

const (
	queueDepth = 256
	// readBuf — буфер одного пакета при чтении с устройства. Ядро отдаёт
	// пакеты не длиннее MTU (GSO-склейку tun.Device режет сам по gso_size),
	// и 64 КБ здесь были 8 МБ RSS на пустом месте: батч в 128 буферов.
	// Пакет длиннее буфера Linux-TUN отдаёт ошибкой, не усечением, поэтому
	// New отказывается от MTU, который сюда не влезает.
	readBuf = 2048
	// writeBuf — ёмкость буфера, в котором пакет уходит в устройство. Linux-TUN
	// с offload склеивает подряд идущие TCP-сегменты одного потока в один
	// большой пакет и один write(2) — но только если в буфере ПЕРВОГО
	// сегмента есть место (tun/offload_linux.go: coalesceInsufficientCap).
	// У транспортов буферы теперь по 2 КБ, склейка в них невозможна, и без
	// этой пересадки каждый пакет стоил системного вызова: +45% CPU на байт
	// (замер 2026-09-02). 32 КБ = до 25 сегментов на вызов; на батч из 128
	// пакетов это не больше 4 МБ, и то лишь под нагрузкой.
	writeBuf = 32 * 1024
)

type packet struct {
	buf  []byte
	size int
}

// Shared — владелец TUN.
type Shared struct {
	inner  tun.Device
	offset int
	mtu    int

	mu     sync.Mutex
	cur    *Handle
	pool   sync.Pool
	wpool  sync.Pool // буферы writeBuf для записи в устройство
	wmu    sync.Mutex
	wbufs  [][]byte // рабочий срез под один Write, чтобы не аллоцировать на каждый
	closed chan struct{}
	once   sync.Once
}

// New запускает читающую горутину. offset — запас перед пакетом, который
// просят транспорты (16 у wireguard-go); читаем сразу с ним.
func New(inner tun.Device, mtu, offset int) *Shared {
	if mtu+64 > readBuf {
		panic(fmt.Sprintf("tunshare: mtu %d не влезает в буфер чтения %d", mtu, readBuf))
	}
	s := &Shared{inner: inner, offset: offset, mtu: mtu, closed: make(chan struct{})}
	s.pool.New = func() any { return make([]byte, offset+mtu+64) }
	s.wpool.New = func() any { return make([]byte, offset+writeBuf) }
	go s.reader()
	return s
}

func (s *Shared) reader() {
	n := s.inner.BatchSize()
	bufs := make([][]byte, n)
	sizes := make([]int, n)
	for i := range bufs {
		bufs[i] = make([]byte, s.offset+readBuf)
	}
	for {
		cnt, err := s.inner.Read(bufs, sizes, s.offset)
		if err != nil {
			s.Close()
			return
		}
		s.mu.Lock()
		h := s.cur
		s.mu.Unlock()
		for i := 0; i < cnt; i++ {
			if sizes[i] == 0 {
				continue
			}
			if h == nil {
				continue // транспорта нет — пакету некуда
			}
			b := s.pool.Get().([]byte)
			if cap(b) < s.offset+sizes[i] {
				b = make([]byte, s.offset+sizes[i])
			}
			b = b[:s.offset+sizes[i]]
			copy(b[s.offset:], bufs[i][s.offset:s.offset+sizes[i]])
			select {
			case h.q <- packet{buf: b, size: sizes[i]}:
			default:
				s.pool.Put(b) // транспорт не успевает — дроп, как сделала бы очередь устройства
			}
		}
	}
}

// Handle выдаёт tun.Device для очередного транспорта; предыдущий Handle
// перестаёт получать пакеты.
func (s *Shared) Handle() *Handle {
	h := &Handle{s: s, q: make(chan packet, queueDepth), done: make(chan struct{}), events: make(chan tun.Event, 4)}
	h.events <- tun.EventUp
	s.mu.Lock()
	old := s.cur
	s.cur = h
	s.mu.Unlock()
	if old != nil {
		old.Close()
	}
	return h
}

// Close останавливает чтение и закрывает устройство.
func (s *Shared) Close() error {
	s.once.Do(func() {
		close(s.closed)
		s.mu.Lock()
		h := s.cur
		s.cur = nil
		s.mu.Unlock()
		if h != nil {
			h.Close()
		}
		s.inner.Close()
	})
	return nil
}

// Handle — tun.Device для одного транспорта.
type Handle struct {
	s      *Shared
	q      chan packet
	done   chan struct{}
	events chan tun.Event
	once   sync.Once
}

func (h *Handle) File() *os.File { return nil }

// Read блокируется до первого пакета, затем добирает без ожидания.
func (h *Handle) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	var p packet
	select {
	case p = <-h.q:
	case <-h.done:
		return 0, os.ErrClosed
	}
	n := 0
	for {
		sizes[n] = copy(bufs[n][offset:], p.buf[h.s.offset:h.s.offset+p.size])
		h.s.pool.Put(p.buf[:cap(p.buf)])
		n++
		if n >= len(bufs) {
			return n, nil
		}
		select {
		case p = <-h.q:
		default:
			return n, nil
		}
	}
}

// Write пересаживает пакеты в буферы с запасом (см. writeBuf) и отдаёт
// устройству одним батчем. Пакет, который в запас не влезает, идёт как есть.
func (h *Handle) Write(bufs [][]byte, offset int) (int, error) {
	select {
	case <-h.done:
		return 0, os.ErrClosed
	default:
	}
	return h.s.write(bufs, offset)
}

func (s *Shared) write(bufs [][]byte, offset int) (int, error) {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	out := s.wbufs[:0]
	for _, b := range bufs {
		if len(b) > offset+writeBuf {
			out = append(out, b)
			continue
		}
		w := s.wpool.Get().([]byte)
		out = append(out, w[:copy(w, b)])
	}
	n, err := s.inner.Write(out, offset)
	for i, w := range out {
		// out[i] — либо bufs[i] как есть, либо буфер из пула; отличаем по адресу.
		if &w[0] != &bufs[i][0] {
			s.wpool.Put(w[:cap(w)])
		}
		out[i] = nil
	}
	s.wbufs = out[:0]
	return n, err
}

func (h *Handle) MTU() (int, error)        { return h.s.mtu, nil }
func (h *Handle) Name() (string, error)    { return h.s.inner.Name() }
func (h *Handle) Events() <-chan tun.Event { return h.events }
func (h *Handle) BatchSize() int           { return h.s.inner.BatchSize() }

// Close отвязывает транспорт; само устройство живёт дальше.
func (h *Handle) Close() error {
	h.once.Do(func() {
		close(h.done)
		close(h.events)
		h.s.mu.Lock()
		if h.s.cur == h {
			h.s.cur = nil
		}
		h.s.mu.Unlock()
	})
	return nil
}
