package engine

import (
	"os"
	"path/filepath"
	"testing"
)

// Хук подбора whitelisted-SNI смотрит на СПИСКИ БЛОКИРОВОК, а не на SkipPaths.
// Разница смысловая: в SkipPaths лежит и whitelist.txt — список «обход не
// включать», — и предлагать сети оттуда значило бы работать против прямо
// высказанной воли оператора.
func TestInBlocklistUsesBlockListsNotSkipPaths(t *testing.T) {
	dir := t.TempDir()
	block := filepath.Join(dir, "rkn.txt")
	excl := filepath.Join(dir, "whitelist.txt")
	if err := os.WriteFile(block, []byte("# РКН\nrutracker.org\n^strict.example\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(excl, []byte("mybank.ru\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	st := newState()
	st.reloadSkipSet(Config{
		SNIWLHostlists: []string{block},
		SNIWLExclude:   []string{excl},
	})

	cases := []struct {
		domain string
		want   bool
	}{
		{"rutracker.org", true},
		// Хостлисты nfqws2 суффиксные: запись покрывает поддомены.
		{"static.rutracker.org", true},
		// Форма `^domain` автоматику поддоменов отменяет.
		{"strict.example", true},
		{"sub.strict.example", false},
		// Исключение оператора сильнее списка блокировок.
		{"mybank.ru", false},
		{"api.mybank.ru", false},
		{"example.org", false},
	}
	for _, c := range cases {
		if got := st.inBlocklist(c.domain); got != c.want {
			t.Errorf("inBlocklist(%q) = %v, ждали %v", c.domain, got, c.want)
		}
	}
}

func TestInBlocklistEmptyWhenNoListsConfigured(t *testing.T) {
	st := newState()
	st.reloadSkipSet(Config{})
	if st.inBlocklist("rutracker.org") {
		t.Error("без списков блокировок хук не должен срабатывать ни на чём")
	}
}

// Наборы обновляются тем же тикером, что и skipSet: оператор дописывает домен
// в extra-domains.txt через вебморду и не перезапускает демон.
func TestReloadSkipSetRefreshesAllThreeSets(t *testing.T) {
	dir := t.TempDir()
	skip := filepath.Join(dir, "skip.txt")
	block := filepath.Join(dir, "block.txt")
	if err := os.WriteFile(skip, []byte("skipped.example\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(block, []byte("blocked.example\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Config{SkipPaths: []string{skip}, SNIWLHostlists: []string{block}}

	st := newState()
	st.reloadSkipSet(cfg)
	st.mu.Lock()
	skipped := st.skippedLocked("skipped.example")
	st.mu.Unlock()
	if !skipped {
		t.Error("skipSet не заполнен")
	}
	if !st.inBlocklist("blocked.example") {
		t.Error("blockSet не заполнен")
	}

	if err := os.WriteFile(block, []byte("blocked.example\nlater.example\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if st.inBlocklist("later.example") {
		t.Fatal("новая запись видна до перечитывания")
	}
	st.reloadSkipSet(cfg)
	if !st.inBlocklist("later.example") {
		t.Error("после перечитывания новая запись не видна")
	}
}
