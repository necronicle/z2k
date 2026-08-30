package sniwl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testStore(t *testing.T) Store {
	t.Helper()
	dir := t.TempDir()
	return NewStore(filepath.Join(dir, "sni_wl_nets.txt"), filepath.Join(dir, "sni_wl_name.txt"))
}

// netLines — только содержательные строки файла сетей: без комментариев и без
// часового. Именно они и есть «найденные сети»; часовой к ним не относится.
func netLines(t *testing.T, path string) []string {
	t.Helper()
	var out []string
	for _, l := range readLines(t, path) {
		if strings.HasPrefix(l, "#") || IsSentinel(l) {
			continue
		}
		out = append(out, l)
	}
	return out
}

// firstContentLine — то, что первым увидит генератор конфига: он выбрасывает
// комментарии и берёт первую непустую строку.
func firstContentLine(t *testing.T, path string) string {
	t.Helper()
	for _, l := range readLines(t, path) {
		if strings.HasPrefix(l, "#") {
			continue
		}
		return l
	}
	return ""
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("чтение %s: %v", path, err)
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func TestStoreMissingFilesAreNotAnError(t *testing.T) {
	// Нормальное состояние 99% установок: сетей не найдено, файлов нет.
	s := testStore(t)
	nets, err := s.LoadNetworks()
	if err != nil {
		t.Fatalf("LoadNetworks: %v", err)
	}
	if len(nets) != 0 {
		t.Errorf("на пустом месте нашлось %d сетей", len(nets))
	}
	name, err := s.LoadName()
	if err != nil {
		t.Fatalf("LoadName: %v", err)
	}
	if name != "" {
		t.Errorf("на пустом месте нашлось имя %q", name)
	}
}

func TestStoreNeverWritesFileWithoutSentinel(t *testing.T) {
	// ПУСТОЙ --ipset для nfqws2 означает не «не совпадать ни с чем», а
	// ОТСУТСТВИЕ ФИЛЬТРА. Файл живой (inotify), поэтому опустевший файл
	// снимает фильтр с профиля прямо в бою: 2026-08-30 его почистили руками, и
	// профиль sni_wl забрал себе chatgpt.com, facebook.com, github.com,
	// instagram.com. Значит записи без часового не бывает.
	s := testStore(t)
	if err := s.SaveNetworks(map[uint32]string{}); err != nil {
		t.Fatalf("SaveNetworks(пусто): %v", err)
	}
	if got := firstContentLine(t, s.NetworksPath); got != SentinelNet {
		t.Fatalf("первая содержательная строка %q, ждали часового %s", got, SentinelNet)
	}
	if got := netLines(t, s.NetworksPath); len(got) != 0 {
		t.Fatalf("на пустой карте в файле оказались сети %v", got)
	}
}

func TestStoreKeepsSentinelWhenLastEntryGoes(t *testing.T) {
	s := testStore(t)
	key, _ := NetKeyString("5.9.100.200")
	if _, err := s.AddNetwork(key, "первая"); err != nil {
		t.Fatalf("AddNetwork: %v", err)
	}
	if err := s.SaveNetworks(map[uint32]string{}); err != nil {
		t.Fatalf("SaveNetworks(пусто): %v", err)
	}
	if _, err := os.Stat(s.NetworksPath); err != nil {
		t.Fatalf("файл сетей исчез: %v — nfqws2 остался бы с ipset без фильтра", err)
	}
	if got := firstContentLine(t, s.NetworksPath); got != SentinelNet {
		t.Fatalf("после опустошения первая содержательная строка %q, ждали %s", got, SentinelNet)
	}
}

func TestStoreSentinelIsNotCountedAsNetwork(t *testing.T) {
	// «Сетей найдено: 1» на файле, где есть только часовой, было бы враньём:
	// часовой — страховка от пустого ipset, а не поражённая сеть.
	s := testStore(t)
	if err := s.SaveNetworks(map[uint32]string{}); err != nil {
		t.Fatal(err)
	}
	nets, err := s.LoadNetworks()
	if err != nil {
		t.Fatalf("LoadNetworks: %v", err)
	}
	if len(nets) != 0 {
		t.Fatalf("часовой прочитан как %d поражённых сетей: %v", len(nets), nets)
	}
	// И он не занимает слот: сеть 192.0.0.0/16 — это не он.
	key, _ := NetKeyString("192.0.5.7")
	added, err := s.AddNetwork(key, "реальная сеть рядом с часовым")
	if err != nil || !added {
		t.Fatalf("AddNetwork(192.0.0.0/16): added=%v err=%v", added, err)
	}
	if got := netLines(t, s.NetworksPath); len(got) != 1 || got[0] != "192.0.0.0/16" {
		t.Fatalf("в файле %v, ждали ровно [192.0.0.0/16] помимо часового", got)
	}
}

func TestStoreSentinelSurvivesRewriteAndDedup(t *testing.T) {
	s := testStore(t)
	for _, ip := range []string{"5.9.100.200", "88.198.1.1", "5.9.0.1"} {
		key, _ := NetKeyString(ip)
		if _, err := s.AddNetwork(key, "по адресу "+ip); err != nil {
			t.Fatalf("AddNetwork(%s): %v", ip, err)
		}
	}
	body, err := os.ReadFile(s.NetworksPath)
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(body), SentinelNet+"\n"); n != 1 {
		t.Fatalf("часовой встречается %d раз:\n%s", n, body)
	}
	if got := firstContentLine(t, s.NetworksPath); got != SentinelNet {
		t.Errorf("после трёх перезаписей первая содержательная строка %q", got)
	}
	if got := netLines(t, s.NetworksPath); len(got) != 2 {
		t.Errorf("сетей в файле %v, ждали 2 (третий адрес — та же /16)", got)
	}
}

func TestStoreSentinelHasCommentAboveIt(t *testing.T) {
	// Мануал nfqws2: комментарий — только целая строка на '#'. Пояснение
	// обязано стоять НАД часовым, иначе оно уедет в парсер как часть CIDR.
	s := testStore(t)
	if err := s.SaveNetworks(map[uint32]string{}); err != nil {
		t.Fatal(err)
	}
	lines := readLines(t, s.NetworksPath)
	idx := -1
	for i, l := range lines {
		if IsSentinel(l) {
			idx = i
			break
		}
	}
	if idx <= 0 {
		t.Fatalf("часовой стоит на позиции %d — над ним нет пояснения: %v", idx, lines)
	}
	for i := 0; i < idx; i++ {
		if !strings.HasPrefix(lines[i], "#") {
			t.Fatalf("строка %d над часовым не комментарий: %q", i, lines[i])
		}
	}
	if !strings.Contains(strings.Join(lines[:idx], " "), "192.0.2.0/24") {
		t.Error("пояснение над часовым не называет саму сеть — читать его будет человек")
	}
}

func TestEnsureSentinelRepairsExistingFile(t *testing.T) {
	// Файл переживает нас: его чистят руками, его рвёт потеря питания. Любой
	// такой файл уже скормлен работающему nfqws2, поэтому демон на старте
	// дописывает часового.
	s := testStore(t)
	if err := os.WriteFile(s.NetworksPath, []byte("# руками\n77.88.0.0/16\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	fixed, err := s.EnsureSentinel()
	if err != nil || !fixed {
		t.Fatalf("EnsureSentinel: fixed=%v err=%v", fixed, err)
	}
	if got := firstContentLine(t, s.NetworksPath); got != SentinelNet {
		t.Fatalf("первая содержательная строка %q, ждали часового", got)
	}
	body, _ := os.ReadFile(s.NetworksPath)
	for _, want := range []string{"77.88.0.0/16", "# руками"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("починка потеряла %q:\n%s", want, body)
		}
	}
	// Повторный вызов не дёргает файл: inotify nfqws2 не любит пустых правок.
	before, _ := os.ReadFile(s.NetworksPath)
	fixed, err = s.EnsureSentinel()
	if err != nil || fixed {
		t.Fatalf("повторный EnsureSentinel: fixed=%v err=%v", fixed, err)
	}
	after, _ := os.ReadFile(s.NetworksPath)
	if string(before) != string(after) {
		t.Error("файл переписан, хотя часовой уже был на месте")
	}
}

func TestEnsureSentinelRepairsEmptiedFile(t *testing.T) {
	// Ровно поле 2026-08-30: файл почистили, чтобы проверить подбор.
	s := testStore(t)
	if err := os.WriteFile(s.NetworksPath, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	fixed, err := s.EnsureSentinel()
	if err != nil || !fixed {
		t.Fatalf("EnsureSentinel: fixed=%v err=%v", fixed, err)
	}
	if got := firstContentLine(t, s.NetworksPath); got != SentinelNet {
		t.Fatalf("опустошённый файл остался без часового: %q", got)
	}
}

func TestEnsureSentinelDoesNotCreateFile(t *testing.T) {
	// У тех, кто кампанию не гонял, файла нет и конфиг не меняется ни на байт.
	// Появление файла из ниоткуда включило бы им профиль sni_wl.
	s := testStore(t)
	fixed, err := s.EnsureSentinel()
	if err != nil || fixed {
		t.Fatalf("EnsureSentinel на пустом месте: fixed=%v err=%v", fixed, err)
	}
	if _, err := os.Stat(s.NetworksPath); !os.IsNotExist(err) {
		t.Fatal("файл сетей создан из ничего")
	}
}

func TestIsSentinelMatchesNetworkNotText(t *testing.T) {
	for _, ok := range []string{"192.0.2.0/24", " 192.0.2.0/24 ", "192.0.2.7/24"} {
		if !IsSentinel(ok) {
			t.Errorf("%q не опознан как часовой", ok)
		}
	}
	for _, bad := range []string{"", "192.0.2.0/16", "192.0.0.0/16", "5.9.0.0/16", "# 192.0.2.0/24", "не сеть"} {
		if IsSentinel(bad) {
			t.Errorf("%q принят за часового", bad)
		}
	}
}

func TestStoreAddNetworkDedups(t *testing.T) {
	s := testStore(t)
	key, _ := NetKeyString("5.9.100.200")

	added, err := s.AddNetwork(key, "имя disk.rzd.ru")
	if err != nil || !added {
		t.Fatalf("первая запись: added=%v err=%v", added, err)
	}
	// Тот же ключ из другого адреса той же сети — это та же запись.
	same, _ := NetKeyString("5.9.0.1")
	added, err = s.AddNetwork(same, "имя disk.rzd.ru")
	if err != nil {
		t.Fatalf("повторная запись: %v", err)
	}
	if added {
		t.Error("сеть добавлена дважды — nfqws2 получил бы дубль в ipset")
	}

	cidrs := netLines(t, s.NetworksPath)
	if len(cidrs) != 1 || cidrs[0] != "5.9.0.0/16" {
		t.Fatalf("в файле %v, ждали ровно [5.9.0.0/16]", cidrs)
	}
}

func TestStoreNetworksRoundTripSorted(t *testing.T) {
	s := testStore(t)
	for _, ip := range []string{"88.198.1.1", "5.9.100.200", "45.10.0.1"} {
		key, ok := NetKeyString(ip)
		if !ok {
			t.Fatalf("%s не дал ключа", ip)
		}
		if _, err := s.AddNetwork(key, "по домену "+ip); err != nil {
			t.Fatalf("AddNetwork(%s): %v", ip, err)
		}
	}
	cidrs := netLines(t, s.NetworksPath)
	want := []string{"5.9.0.0/16", "45.10.0.0/16", "88.198.0.0/16"}
	if len(cidrs) != len(want) {
		t.Fatalf("в файле %v, ждали %v", cidrs, want)
	}
	for i := range want {
		if cidrs[i] != want[i] {
			t.Errorf("строка %d = %s, ждали %s (порядок должен быть детерминированным)", i, cidrs[i], want[i])
		}
	}
	back, err := s.LoadNetworks()
	if err != nil {
		t.Fatalf("LoadNetworks: %v", err)
	}
	if len(back) != 3 {
		t.Fatalf("прочитано %d сетей, ждали 3", len(back))
	}
}

func TestStoreCommentsAreOwnLines(t *testing.T) {
	// Мануал nfqws2: «Пустые строки и строки, начинающиеся с #, игнорируются».
	// Хвостовых комментариев в этом формате нет, поэтому провенанс обязан
	// стоять НАД записью, иначе он попадёт в парсер как часть CIDR.
	s := testStore(t)
	key, _ := NetKeyString("5.9.100.200")
	if _, err := s.AddNetwork(key, "имя disk.rzd.ru"); err != nil {
		t.Fatalf("AddNetwork: %v", err)
	}
	lines := readLines(t, s.NetworksPath)
	// Хвост файла после блока часового: провенанс отдельной строкой и CIDR.
	tail := lines[len(lines)-2:]
	if !strings.HasPrefix(tail[0], provenancePrefix) {
		t.Errorf("над записью не провенанс: %q (весь файл: %v)", tail[0], lines)
	}
	if strings.Contains(tail[1], "#") {
		t.Errorf("в строке с CIDR оказался комментарий: %q", tail[1])
	}
	if tail[1] != "5.9.0.0/16" {
		t.Errorf("строка CIDR = %q", tail[1])
	}
	if got := netLines(t, s.NetworksPath); len(got) != 1 {
		t.Errorf("содержательных строк %v, ждали одну сеть", got)
	}
}

func TestStorePreservesForeignEntriesAndComments(t *testing.T) {
	// Оператор мог вписать сеть руками и объяснить почему. Перезапись не
	// имеет права ни потерять запись, ни оторвать от неё объяснение.
	s := testStore(t)
	if err := os.WriteFile(s.NetworksPath,
		[]byte("# руками: у соседа тот же провайдер\n77.88.0.0/16\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	key, _ := NetKeyString("5.9.100.200")
	if _, err := s.AddNetwork(key, "наша находка"); err != nil {
		t.Fatalf("AddNetwork: %v", err)
	}
	body, err := os.ReadFile(s.NetworksPath)
	if err != nil {
		t.Fatal(err)
	}
	got := string(body)
	for _, want := range []string{"77.88.0.0/16", "5.9.0.0/16", "у соседа тот же провайдер"} {
		if !strings.Contains(got, want) {
			t.Errorf("после перезаписи потеряно %q:\n%s", want, got)
		}
	}
}

func TestStoreNameRoundTrip(t *testing.T) {
	s := testStore(t)
	if err := s.SetName("DISK.RZD.RU", "сеть 5.9.0.0/16"); err != nil {
		t.Fatalf("SetName: %v", err)
	}
	got, err := s.LoadName()
	if err != nil {
		t.Fatalf("LoadName: %v", err)
	}
	if got != "disk.rzd.ru" {
		t.Errorf("имя %q, ждали disk.rzd.ru в нижнем регистре", got)
	}
	lines := readLines(t, s.NamePath)
	if len(lines) != 2 || !strings.HasPrefix(lines[0], provenancePrefix) {
		t.Errorf("файл имени: %v", lines)
	}
	// Замена имени не должна оставлять хвост от прежнего.
	if err := s.SetName("akashi.vk-portal.net", "сеть 88.198.0.0/16"); err != nil {
		t.Fatalf("SetName повторно: %v", err)
	}
	got, _ = s.LoadName()
	if got != "akashi.vk-portal.net" {
		t.Errorf("после замены имя %q", got)
	}
	if len(readLines(t, s.NamePath)) != 2 {
		t.Error("после замены в файле больше одной записи")
	}
}

func TestStoreSetNameEmptyRemovesFile(t *testing.T) {
	s := testStore(t)
	if err := s.SetName("disk.rzd.ru", "x"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetName("", ""); err != nil {
		t.Fatalf("SetName(пусто): %v", err)
	}
	if _, err := os.Stat(s.NamePath); !os.IsNotExist(err) {
		t.Fatal("файл имени остался — профиль подставил бы пустое имя")
	}
}

func TestStoreSetNameRejectsGarbage(t *testing.T) {
	s := testStore(t)
	if err := s.SetName("не имя вовсе", "x"); err == nil {
		t.Fatal("мусор принят как имя для ClientHello")
	}
	if _, err := os.Stat(s.NamePath); !os.IsNotExist(err) {
		t.Error("после отказа файл всё-таки создан")
	}
}

func TestStoreLoadNameSkipsComments(t *testing.T) {
	s := testStore(t)
	if err := os.WriteFile(s.NamePath,
		[]byte("# провенанс\n\n   \nvk.com\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := s.LoadName()
	if err != nil {
		t.Fatal(err)
	}
	if got != "vk.com" {
		t.Errorf("имя %q, ждали vk.com", got)
	}
}

func TestWriteAtomicLeavesNoTemp(t *testing.T) {
	// nfqws2 держит на этих файлах inotify: недописанный файл — это
	// недописанный фильтр в бою, поэтому только tmp+rename в том же каталоге.
	dir := t.TempDir()
	path := filepath.Join(dir, "sni_wl_nets.txt")
	if err := writeAtomic(path, "5.9.0.0/16\n"); err != nil {
		t.Fatal(err)
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 1 || ents[0].Name() != "sni_wl_nets.txt" {
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		t.Fatalf("в каталоге %v — временный файл не убран", names)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o644 {
		t.Errorf("права %v, ждали 0644 — файл читает nfqws2", fi.Mode().Perm())
	}
}

func TestSanitiseKeepsOneLine(t *testing.T) {
	got := sanitise("две\nстроки\tи\rвозврат")
	if strings.ContainsAny(got, "\n\r\t") {
		t.Errorf("перенос уцелел: %q", got)
	}
	long := sanitise(strings.Repeat("я", 400))
	if len([]byte(long)) > 200 {
		t.Errorf("деталь %d байт, ждали не больше 200", len([]byte(long)))
	}
	// Обрубок половины руны в файле, который читают глазами, недопустим.
	for _, r := range long {
		if r == '\uFFFD' {
			t.Fatal("обрезано по границе байта, а не руны")
		}
	}
}

// Пути — контракт с генератором конфига (lib/config_official.sh, профиль
// sni_wl): он читает ровно эти файлы и по файлу сетей гейтит весь профиль.
// Переименование здесь без правки генератора выглядит как «подбор не работает»,
// и искать причину будут в пробе, а не в имени файла. Поэтому пути прибиты
// тестом.
func TestDefaultPathsMatchConfigGenerator(t *testing.T) {
	cases := []struct{ got, want string }{
		{DefaultCandidatesPath, "/opt/zapret2/lists/sni_wl_candidates.txt"},
		{DefaultNetworksPath, "/opt/zapret2/lists/sni_wl_nets.txt"},
		{DefaultNamePath, "/opt/zapret2/lists/sni_wl_name.txt"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("путь %q, генератор ждёт %q", c.got, c.want)
		}
	}
}

// Имя, записанное нами, обязано пройти проверку генератора
// (`*[!A-Za-z0-9.-]*|.*|-*|*.|*-|*..*`, длина <= 253). Иначе профиль молча не
// соберётся, а выглядеть это будет как «подбор не сработал».
func TestNameValidationMatchesConfigGenerator(t *testing.T) {
	// Дефис внутри метки генератор пропускает (его глоб `*-` ловит только
	// дефис в САМОМ конце имени) — значит и мы обязаны пропускать, иначе
	// отбросим кандидата, который бы прекрасно работал.
	ok := []string{"disk.rzd.ru", "akashi.vk-portal.net", "300.ya.ru", "2gis.com", "odd-.label.ru"}
	for _, n := range ok {
		if !validHostname(n) {
			t.Errorf("%q отвергнуто, а генератор его примет", n)
		}
	}
	bad := []string{
		"has_underscore.ru", // генератор не пропускает '_'
		"-leading.ru",
		"ends.with.dash-",
		".leading.ru",
		"trailing.ru.",
		"double..dot.ru",
		"with space.ru",
		"colon:in.name",
		"comma,in.name",
		// Строже генератора СОЗНАТЕЛЬНО: бездоменное имя он бы пропустил, но
		// кандидатом в белый список коробки оно быть не может. Строгость в эту
		// сторону безопасна — мы никогда не запишем то, что он отвергнет.
		"nodot",
		"",
		strings.Repeat("a.", 200) + "ru",
	}
	for _, n := range bad {
		if validHostname(n) {
			t.Errorf("%q принято, а генератор его отвергнет — профиль не соберётся", n)
		}
	}
}
