package main

// Охраняет фикс 2026-08-14: проверка «домен уже в списке» обязана понимать
// суффиксы — ровно так, как их понимает nfqws2 («в хостлистах поддомены
// учитываются автоматически») и движковый skip-список (engine.skippedLocked).
// Точное сравнение заставляло [Y] отвечать «НЕ в списках — добавьте в
// extra-domains» на поддомены уже покрытых доменов, и люди засоряли
// extra-domains записями, которые ничего не меняли.

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCoversDomain(t *testing.T) {
	cases := []struct {
		entry, needle string
		want          bool
	}{
		{"googlevideo.com", "googlevideo.com", true},
		{"googlevideo.com", "rr3---sn-4g5e6nez.googlevideo.com", true},
		// Якорь по точке: похожее имя — не поддомен.
		{"googlevideo.com", "evilgooglevideo.com", false},
		{"rutracker.org", "www.rutracker.org", true},
		{"www.rutracker.org", "rutracker.org", false},
		// nfqws2-форма «без поддоменов».
		{"^example.com", "example.com", true},
		{"^example.com", "www.example.com", false},
	}
	for _, c := range cases {
		if got := coversDomain(c.entry, c.needle); got != c.want {
			t.Errorf("coversDomain(%q, %q) = %v, ожидалось %v", c.entry, c.needle, got, c.want)
		}
	}
}

func TestScanForDomainSuffixAndCase(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "list.txt")
	content := "# комментарий\nGoogleVideo.com\n\nrutracker.org\n"
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	open := func() *os.File {
		f, err := os.Open(p)
		if err != nil {
			t.Fatal(err)
		}
		return f
	}

	f := open()
	if !scanForDomain(f, "rr1.googlevideo.com") {
		t.Error("поддомен записи из списка должен считаться покрытым")
	}
	f.Close()

	f = open()
	if scanForDomain(f, "evilrutracker.org") {
		t.Error("похожее имя без точки-якоря покрытым считаться не должно")
	}
	f.Close()
}
