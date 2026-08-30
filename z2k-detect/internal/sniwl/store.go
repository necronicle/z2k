package sniwl

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Умолчания путей. Оба файла лежат рядом с остальными списками z2k и оба
// читает генератор конфига.
const (
	// DefaultCandidatesPath — 204 строки, отгружается install.sh как
	// shipped-replace. Порядок в нём и есть приоритет перебора.
	DefaultCandidatesPath = "/opt/zapret2/lists/sni_wl_candidates.txt"
	// DefaultNetworksPath — файл для --ipset профиля: по одному CIDR /16.
	// Имя согласовано с генератором конфига (lib/config_official.sh,
	// профиль sni_wl): он читает ровно этот путь и по нему же гейтит профиль.
	DefaultNetworksPath = "/opt/zapret2/lists/sni_wl_nets.txt"
	// DefaultNamePath — одно имя-победитель, которое уходит в sni= фейка.
	DefaultNamePath = "/opt/zapret2/lists/sni_wl_name.txt"
)

// provenancePrefix помечает строки, которые написали мы. Оператор по нему
// отличает наши записи от своих, а мы — сохраняем чужие при перезаписи.
const provenancePrefix = "# z2k-detect:sniwl:"

// SentinelNet — ЧАСОВОЙ файла сетей: строка, которая стоит в нём всегда.
//
// ПОЧЕМУ ОН ВООБЩЕ ЕСТЬ. Файл уходит в nfqws2 как --ipset, и ПУСТОЙ ipset для
// него означает не «не совпадать ни с чем», а ОТСУТСТВИЕ ФИЛЬТРА. Файл живой:
// nfqws2 держит на нём inotify и перечитывает без перезапуска, поэтому
// опустошить его на работающем роутере — значит снять фильтр у профиля прямо
// в бою. Так и вышло 2026-08-30: файл почистили руками для проверки подбора, и
// профиль sni_wl, вместо поражённых сетей, забрал себе весь заблокированный
// трафик — в его пул уехали chatgpt.com, facebook.com, github.com,
// instagram.com. Это не теория, это снято с живого роутера.
//
// ПОЧЕМУ ИМЕННО ЭТА СЕТЬ. 192.0.2.0/24 — RFC 5737 TEST-NET-1, зарезервирована
// под документацию; реального трафика в ней не бывает ни у кого. Пока в файле
// только часовой, ipset непустой и не совпадает ни с одним живым пакетом —
// профиль собирается, но не срабатывает никогда. Это и есть безопасное
// состояние «фильтр есть, поражённых сетей ноль».
//
// Часовой НЕ является поражённой сетью и во всех подсчётах, дедупликации и
// в API исключается: иначе «сетей найдено: 1» на пустом файле было бы враньём.
const SentinelNet = "192.0.2.0/24"

// sentinelComment — пояснение НАД часовым. Отдельной строкой на '#': мануал
// nfqws2 допускает в списках только целые строки-комментарии, хвостовых нет.
const sentinelComment = `# z2k-detect:sniwl:sentinel — НЕ УДАЛЯТЬ И НЕ ОСТАВЛЯТЬ ФАЙЛ ПУСТЫМ.
# Пустой --ipset для nfqws2 = фильтра нет вовсе, и профиль sni_wl заберёт весь
# заблокированный трафик (проверено на живом роутере 2026-08-30).
# 192.0.2.0/24 — RFC 5737 TEST-NET-1: реального трафика там не бывает, поэтому
# файл с одной этой строкой означает «поражённых сетей ноль», а не «фильтра нет».`

// IsSentinel — это строка часового?
//
// Сравнение по РАЗОБРАННОЙ сети, а не по тексту: оператор мог записать
// часового как 192.0.2.1/24 или с иным пробелом, и это тот же самый часовой.
// Всё, что часовым не является, идёт дальше обычной записью.
func IsSentinel(line string) bool {
	line = strings.TrimSpace(line)
	if line == "" {
		return false
	}
	if strings.EqualFold(line, SentinelNet) {
		return true
	}
	_, n, err := net.ParseCIDR(line)
	if err != nil {
		return false
	}
	return n.String() == SentinelNet
}

// Store владеет двумя файлами состояния.
//
// ПОЧЕМУ ПЕРЕЗАПИСЬ, А НЕ ДОПИСЫВАНИЕ. discovered-domains.txt дописывается, и
// это правильно для хостлиста: дубль там безвреден. Здесь не так — файл сетей
// должен быть дедуплицирован, а имя вообще одно на файл. И перезапись обязана
// быть атомарной (tmp+rename в том же каталоге): nfqws2 держит на этих файлах
// inotify и перечитывает их без перезапуска, поэтому «половина файла» на диске
// — это половина фильтра в бою.
//
// ФАЙЛ СЕТЕЙ НИКОГДА НЕ БЫВАЕТ ПУСТЫМ. Первой содержательной строкой любой
// записи идёт часовой SentinelNet — и при первой записи, и при любой
// перезаписи, и когда реальных сетей ноль. Причина в SentinelNet: пустой
// --ipset снимает фильтр с профиля, а не выключает его.
//
// Файла может не быть вовсе — это нормальное состояние 99% установок, у
// которых подбор ничего не нашёл: генератор конфига (lib/config_official.sh)
// гейтит профиль по первой СОДЕРЖАТЕЛЬНОЙ строке этого файла, и без файла
// профиль не генерируется. Поэтому Store сам файл не создаёт из ничего —
// он лишь следит, чтобы СУЩЕСТВУЮЩИЙ файл не остался без часового.
type Store struct {
	NetworksPath string
	NamePath     string
}

// NewStore заполняет пустые пути умолчаниями.
func NewStore(networksPath, namePath string) Store {
	if networksPath == "" {
		networksPath = DefaultNetworksPath
	}
	if namePath == "" {
		namePath = DefaultNamePath
	}
	return Store{NetworksPath: networksPath, NamePath: namePath}
}

// LoadNetworks читает файл сетей в карту «ключ /16 → комментарий над ним».
// Отсутствие файла — не ошибка: это нормальное состояние 99% установок.
func (s Store) LoadNetworks() (map[uint32]string, error) {
	out := make(map[uint32]string)
	f, err := os.Open(s.NetworksPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return out, nil
		}
		return out, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	pending := ""
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case line == "":
			pending = ""
			continue
		case strings.HasPrefix(line, "#"):
			// Комментарий непосредственно НАД записью считаем её
			// провенансом и сохраняем при перезаписи — оператор мог
			// вписать сеть руками и объяснить почему.
			pending = line
			continue
		case IsSentinel(line):
			// Часовой — не поражённая сеть, а страховка от пустого
			// ipset. В карту он не попадает: иначе он поехал бы в
			// счётчики, в дедуп и в вебморду как найденная сеть.
			// Заодно роняем pending: пояснение над часовым принадлежит
			// ему, а не следующей записи.
			pending = ""
			continue
		}
		key, ok := ParseCIDR16(line)
		if !ok {
			pending = ""
			continue
		}
		if _, dup := out[key]; !dup {
			out[key] = pending
		}
		pending = ""
	}
	return out, sc.Err()
}

// SaveNetworks атомарно перезаписывает файл сетей.
//
// Часовой пишется ВСЕГДА и первым — в том числе когда реальных сетей ноль.
// Пустая карта здесь означает не «удалить файл», а «оставить один часовой»:
// удаление и опустошение одинаково означали бы для nfqws2 снятие фильтра с
// уже работающего профиля, а это ровно тот случай, который увели весь
// заблокированный трафик в пул sni_wl на живом роутере.
func (s Store) SaveNetworks(nets map[uint32]string) error {
	var b strings.Builder
	b.WriteString(sentinelComment)
	b.WriteByte('\n')
	b.WriteString(SentinelNet)
	b.WriteByte('\n')
	for _, k := range sortedKeys(nets) {
		if c := nets[k]; c != "" {
			b.WriteString(c)
			b.WriteByte('\n')
		}
		b.WriteString(CIDR(k))
		b.WriteByte('\n')
	}
	return writeAtomic(s.NetworksPath, b.String())
}

// EnsureSentinel чинит УЖЕ СУЩЕСТВУЮЩИЙ файл сетей, в котором часового нет.
// Второе значение — пришлось ли писать.
//
// Зачем отдельный вызов. Файл переживает нас: его правят руками, его чистят
// «чтобы проверить подбор», его портит недописанная запись после потери
// питания. Любой такой файл уже скормлен работающему nfqws2 по --ipset, и без
// часового пустота в нём означает снятый фильтр. Поэтому демон на старте
// смотрит на файл и дописывает часового, если его нет.
//
// Файла нет — не создаём: у тех, кто кампанию не гонял, конфиг не меняется ни
// на байт, и появление файла из ниоткуда включило бы им профиль sni_wl.
// Часовой уже на месте — не трогаем: лишняя перезапись дёргает inotify
// nfqws2 на каждом старте демона.
func (s Store) EnsureSentinel() (bool, error) {
	f, err := os.Open(s.NetworksPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	found := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		if IsSentinel(sc.Text()) {
			found = true
			break
		}
	}
	scanErr := sc.Err()
	if cerr := f.Close(); cerr != nil && scanErr == nil {
		scanErr = cerr
	}
	if scanErr != nil {
		return false, scanErr
	}
	if found {
		return false, nil
	}
	nets, err := s.LoadNetworks()
	if err != nil {
		return false, err
	}
	if err := s.SaveNetworks(nets); err != nil {
		return false, err
	}
	return true, nil
}

// AddNetwork добавляет сеть, если её там ещё нет. Второе значение — была ли
// запись действительно новой.
func (s Store) AddNetwork(key uint32, detail string) (bool, error) {
	nets, err := s.LoadNetworks()
	if err != nil {
		return false, err
	}
	if _, ok := nets[key]; ok {
		return false, nil
	}
	nets[key] = provenance(detail)
	if err := s.SaveNetworks(nets); err != nil {
		return false, err
	}
	return true, nil
}

// LoadName читает действующее имя-победитель. Пустая строка = имени нет.
func (s Store) LoadName() (string, error) {
	f, err := os.Open(s.NamePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		line = strings.ToLower(line)
		if validHostname(line) {
			return line, nil
		}
	}
	return "", sc.Err()
}

// SetName атомарно записывает имя. Пустое имя удаляет файл — по той же
// причине, что и у файла сетей: гейт генератора смотрит на размер.
func (s Store) SetName(name, detail string) error {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "" {
		if err := os.Remove(s.NamePath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	if !validHostname(name) {
		return fmt.Errorf("sniwl: имя %q не годится для SNI", name)
	}
	return writeAtomic(s.NamePath, provenance(detail)+"\n"+name+"\n")
}

func provenance(detail string) string {
	ts := time.Now().UTC().Format(time.RFC3339)
	return provenancePrefix + ts + ":" + sanitise(detail)
}

// sanitise делает из детали одну строку: файл читают и awk-ом, и человеком.
func sanitise(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\t", " ")
	if len(s) > 200 {
		// Режем по границе рун: деталь бывает кириллической, а обрубок
		// половины руны попадёт в файл, который читают глазами.
		r := []rune(s)
		for len(string(r)) > 200 {
			r = r[:len(r)-1]
		}
		s = string(r)
	}
	return s
}

// writeAtomic пишет через временный файл в ТОМ ЖЕ каталоге и переименовывает.
// Тот же каталог обязателен: rename между файловыми системами не атомарен и
// на роутере просто не сработает (/tmp — tmpfs, /opt — флешка).
func writeAtomic(path, content string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		if tmpName != "" {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	tmpName = ""
	return nil
}
