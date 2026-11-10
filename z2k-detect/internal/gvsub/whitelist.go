package gvsub

import (
	"bufio"
	"compress/gzip"
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

type hostFlags struct{ strict, exempt bool }

type whitelist struct {
	mu     sync.Mutex
	path   string
	mtime  time.Time
	size   int64
	loaded bool
	hosts  map[string]hostFlags
}

// whitelisted сверяет имя ВОПРОСА: клиент обращается к нему (SNI), а CNAME
// лишь выбирает сервер размещения. Исключается весь ответ, включая A/AAAA
// под конечными именами цепочки; цели CNAME не заменяют клиентское имя.
func (s *Service) whitelisted(name string) bool {
	w := &s.whitelist
	w.mu.Lock()
	defer w.mu.Unlock()
	w.reload(s.Whitelist)
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	full := true
	for {
		if flags, ok := w.hosts[name]; ok && (!flags.strict || full) {
			return !flags.exempt
		}
		_, rest, ok := strings.Cut(name, ".")
		if !ok {
			return false
		}
		name, full = rest, false
	}
}

// reload проверяет ту же пару mtime/size, что движок. Отсутствие файла —
// пустой whitelist; при других ошибках оставляем последний успешный снимок.
func (w *whitelist) reload(path string) {
	if path == "" {
		w.loaded, w.hosts = false, nil
		w.path = path
		return
	}
	st, err := os.Stat(path)
	if os.IsNotExist(err) {
		w.loaded, w.hosts = false, nil
		w.path = path
		return
	}
	if err != nil {
		log.Printf("gvsub: whitelist: %v", err)
		return
	}
	if w.loaded && w.path == path && w.mtime.Equal(st.ModTime()) && w.size == st.Size() {
		return
	}
	f, err := os.Open(path)
	if err != nil {
		log.Printf("gvsub: whitelist: %v", err)
		return
	}
	defer f.Close()
	// Сигнатура относится к открытому файлу, даже при атомарной замене пути.
	st, err = f.Stat()
	if err != nil {
		log.Printf("gvsub: whitelist: %v", err)
		return
	}
	hosts, err := readHostlist(f)
	if err != nil {
		log.Printf("gvsub: whitelist: %v", err)
		return
	}
	w.path, w.mtime, w.size, w.hosts, w.loaded = path, st.ModTime(), st.Size(), hosts, true
}

// readHostlist повторяет addpool/SearchHostList из nfq2/hostlist.c:
// комментарии # ; /, первый токен, регистр, ^ (точное имя), ! (исключение),
// первая запись при дубликатах. Gzip определяется сигнатурой, как в движке.
func readHostlist(r io.Reader) (map[string]hostFlags, error) {
	br := bufio.NewReader(r)
	var source io.Reader = br
	if magic, _ := br.Peek(2); len(magic) == 2 && magic[0] == 0x1f && magic[1] == 0x8b {
		z, err := gzip.NewReader(br)
		if err != nil {
			return nil, err
		}
		defer z.Close()
		source = z
	}
	b, err := io.ReadAll(source)
	if err != nil {
		return nil, err
	}
	hosts := map[string]hostFlags{}
	for _, line := range strings.FieldsFunc(string(b), func(c rune) bool { return c == '\r' || c == '\n' || c == 0 }) {
		line = strings.TrimLeft(line, " \t")
		if line == "" || strings.ContainsRune("#;/", rune(line[0])) {
			continue
		}
		flags := hostFlags{}
		for len(line) > 0 && (line[0] == '^' || line[0] == '!') {
			if line[0] == '^' {
				flags.strict = true
			} else {
				flags.exempt = true
			}
			line = line[1:]
		}
		if i := strings.IndexAny(line, " \t"); i >= 0 {
			line = line[:i]
		}
		line = strings.ToLower(line)
		if _, exists := hosts[line]; !exists {
			hosts[line] = flags
		}
	}
	return hosts, nil
}
