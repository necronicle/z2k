package engine

// Охраняет фикс 2026-08-14 (находка код-ревью, уверенность 95).
//
// nfqws2 понимает в хостлистах форму `^domain` — «строгое совпадение, без
// поддоменов» (мануал bol-van, раздел про формат хостлистов). readHostlist
// клал строку в skipSet КАК ЕСТЬ, поэтому ключом становилось буквально
// "^example.com", и ни точное сравнение, ни обход родительских меток в
// skippedLocked с ним не совпадали НИКОГДА.
//
// Направление отказа — худшее из возможных: whitelist.txt («operator
// whitelist (no-bypass)») входит в SkipPaths, то есть оператор пишет туда
// домен именно чтобы обход НЕ включался. Промах skip-списка означает, что
// демон пробьёт такой домен и при вердикте Hot допишет его в
// discovered-domains.txt — включит обход ровно там, где его явно запретили.
//
// Отдельно проверяется, что заявленный паритет с coversDomain из
// cmd/z2k-detect действительно есть: комментарий там на него ссылается.

import (
	"os"
	"testing"
)

func TestSkippedLocked_CaretFormIsExactOnly(t *testing.T) {
	s := newState()
	// Представление ПОСЛЕ readHostlist: '^' срезан, строгость — в значении.
	// Отдельный тест ниже охраняет сам разбор.
	s.skipSet["tracker.example.com"] = true // была ^tracker.example.com
	s.skipSet["googlevideo.com"] = false    // обычная: с поддоменами

	cases := []struct {
		domain string
		want   bool
		why    string
	}{
		{"tracker.example.com", true, "caret-запись обязана покрывать сама себя"},
		{"sub.tracker.example.com", false, "caret-запись НЕ покрывает поддомены — в этом её смысл"},
		{"example.com", false, "родитель caret-записи не покрыт"},
		{"googlevideo.com", true, "обычная запись покрывает себя"},
		{"rr3---sn-x.googlevideo.com", true, "обычная запись покрывает поддомены"},
		{"evilgooglevideo.com", false, "якорь по точке: похожее имя не покрыто"},
	}
	for _, c := range cases {
		s.mu.Lock()
		got := s.skippedLocked(c.domain)
		s.mu.Unlock()
		if got != c.want {
			t.Errorf("skippedLocked(%q) = %v, ожидалось %v — %s", c.domain, got, c.want, c.why)
		}
	}
}

func TestReadHostlistStripsCaret(t *testing.T) {
	dir := t.TempDir()
	p := dir + "/list.txt"
	if err := writeFile(p, "# комментарий\n^Strict.Example.COM\nplain.example.org\n\n"); err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	readHostlist(p, out)

	exact, ok := out["strict.example.com"]
	if !ok {
		t.Fatalf("caret-запись должна лежать в наборе БЕЗ '^', получено: %v", out)
	}
	if !exact {
		t.Error("caret-запись должна быть помечена как строгая (без поддоменов)")
	}
	suffixed, ok := out["plain.example.org"]
	if !ok {
		t.Fatalf("обычная запись потерялась: %v", out)
	}
	if suffixed {
		t.Error("обычная запись не должна быть строгой — она покрывает поддомены")
	}
	if _, bad := out["^strict.example.com"]; bad {
		t.Error("'^' остался в ключе — skippedLocked с таким ключом не совпадёт никогда")
	}
}

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o644)
}
