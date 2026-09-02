package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// asnTable — диапазоны IPv4 → ASN из iptoasn.com (ip2asn-v4.tsv).
// Нужна для одного: отличить «упал узел» от «упал транзит у части
// операторов» по составу когорты, как при разборе 02.09.2026.
type asnTable struct {
	start []uint32
	end   []uint32
	asn   []uint32
	mtime time.Time
}

var asnTab atomic.Pointer[asnTable]

func ip4ToU32(ip net.IP) (uint32, bool) {
	v4 := ip.To4()
	if v4 == nil {
		return 0, false
	}
	return binary.BigEndian.Uint32(v4), true
}

func loadASNTable(path string) (*asnTable, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	t := &asnTable{mtime: st.ModTime()}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	line := 0
	for sc.Scan() {
		line++
		parts := strings.SplitN(sc.Text(), "\t", 4)
		if len(parts) < 3 {
			return nil, fmt.Errorf("%s:%d: не TSV из трёх и более колонок", path, line)
		}
		a, okA := ip4ToU32(net.ParseIP(parts[0]))
		b, okB := ip4ToU32(net.ParseIP(parts[1]))
		n, errN := strconv.ParseUint(parts[2], 10, 32)
		if !okA || !okB || errN != nil || b < a {
			return nil, fmt.Errorf("%s:%d: плохой диапазон %q", path, line, sc.Text())
		}
		if n == 0 {
			continue // незанятые диапазоны iptoasn помечает нулём
		}
		t.start = append(t.start, a)
		t.end = append(t.end, b)
		t.asn = append(t.asn, uint32(n))
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(t.start) == 0 {
		return nil, fmt.Errorf("%s: таблица пуста", path)
	}
	if !sort.SliceIsSorted(t.start, func(i, j int) bool { return t.start[i] < t.start[j] }) {
		return nil, fmt.Errorf("%s: диапазоны не отсортированы", path)
	}
	return t, nil
}

func (t *asnTable) lookup(ip net.IP) uint32 {
	if t == nil {
		return 0
	}
	v, ok := ip4ToU32(ip)
	if !ok {
		return 0
	}
	i := sort.Search(len(t.start), func(i int) bool { return t.start[i] > v }) - 1
	if i < 0 || v > t.end[i] {
		return 0
	}
	return t.asn[i]
}

// asnLookup — точка вызова из событий. Без таблицы отвечает нулём.
func asnLookup(ip string) uint32 {
	return asnTab.Load().lookup(net.ParseIP(ip))
}

// watchASNTable перечитывает файл, когда его mtime изменился: обновление
// раз в неделю кладёт новый файл, релей подхватывает без перезапуска.
func watchASNTable(path string, every time.Duration, stop <-chan struct{}) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	for {
		select {
		case <-tk.C:
			st, err := os.Stat(path)
			if err != nil {
				continue
			}
			cur := asnTab.Load()
			if cur != nil && !st.ModTime().After(cur.mtime) {
				continue
			}
			if t, err := loadASNTable(path); err == nil {
				asnTab.Store(t)
			}
		case <-stop:
			return
		}
	}
}
