//go:build linux

package voiceprobe

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
)

// ОТКУДА БЕРЁТСЯ ЦЕЛЬ.
//
// У голоса нет имени, которое человек мог бы вписать: сервер выдаётся на
// сессию, и в публичном DNS его нет (проверено 04.09: discord.media
// резолвится, russiaNNNN.discord.media — нет). Значит поля ввода у этого
// замера быть не может в принципе, и цель приходит из наблюдения за живым
// разговором.
//
// Читаем conntrack ядра. Не свой учёт, не журнал движка: conntrack видит поток
// независимо от того, попал он под наш профиль или нет, — а нам как раз важно
// померить и то, что мимо профиля прошло.

// voicePorts — диапазоны, на которых живёт голос Дискорда.
// Те же, что в боевом профиле (lib/config_official.sh, discord_udp): если они
// разъедутся, зонд начнёт мерить не тот трафик, который обходит движок.
var voicePorts = []struct{ lo, hi int }{
	{50000, 50100},
	{1400, 1400},
	{3478, 3481},
	{5349, 5349},
	{19294, 19344},
}

func isVoicePort(p int) bool {
	for _, r := range voicePorts {
		if p >= r.lo && p <= r.hi {
			return true
		}
	}
	return false
}

// Target — куда слать зонд.
type Target struct {
	IP   net.IP
	Port int
	// Packets — сколько пакетов ядро насчитало в этом потоке. По нему
	// выбирается самый живой разговор, если их несколько.
	Packets int
}

func (t Target) String() string { return net.JoinHostPort(t.IP.String(), strconv.Itoa(t.Port)) }

// ConntrackPath — где лежит таблица. Отдельной переменной ради тестов.
var ConntrackPath = "/proc/net/nf_conntrack"

// FindVoiceTargets ищет живые голосовые потоки.
//
// Возвращает их по убыванию числа пакетов: первым идёт самый нагруженный, то
// есть тот разговор, который человек прямо сейчас и ведёт.
func FindVoiceTargets() ([]Target, error) {
	f, err := os.Open(ConntrackPath)
	if err != nil {
		return nil, fmt.Errorf("voiceprobe: не читается таблица соединений (%v); "+
			"без неё цель взять неоткуда", err)
	}
	defer f.Close()

	seen := map[string]*Target{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !strings.Contains(line, "udp") {
			continue
		}
		dst, dport, packets, ok := parseConntrackUDP(line)
		if !ok || !isVoicePort(dport) {
			continue
		}
		// Свои же адреса не цель: голос идёт наружу.
		if dst.IsLoopback() || dst.IsPrivate() || dst.IsLinkLocalUnicast() {
			continue
		}
		key := dst.String() + ":" + strconv.Itoa(dport)
		if t, exists := seen[key]; exists {
			t.Packets += packets
			continue
		}
		seen[key] = &Target{IP: dst, Port: dport, Packets: packets}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	out := make([]Target, 0, len(seen))
	for _, t := range seen {
		out = append(out, *t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Packets > out[j].Packets })
	return out, nil
}

// parseConntrackUDP разбирает строку conntrack: адрес назначения, порт
// назначения и число пакетов в исходящем направлении.
//
// Формат строки на разных ядрах отличается началом (есть или нет колонка
// семейства), поэтому идём по парам «ключ=значение», а не по номерам полей.
// Берём ПЕРВЫЕ dst/dport — они относятся к исходному направлению, то есть к
// тому, куда клиент шлёт.
func parseConntrackUDP(line string) (dst net.IP, dport, packets int, ok bool) {
	var haveDst, haveDport bool
	for _, f := range strings.Fields(line) {
		k, v, found := strings.Cut(f, "=")
		if !found {
			continue
		}
		switch k {
		case "dst":
			if !haveDst {
				if ip := net.ParseIP(v); ip != nil {
					dst, haveDst = ip, true
				}
			}
		case "dport":
			if !haveDport {
				if n, err := strconv.Atoi(v); err == nil {
					dport, haveDport = n, true
				}
			}
		case "packets":
			if n, err := strconv.Atoi(v); err == nil && packets == 0 {
				packets = n
			}
		}
	}
	return dst, dport, packets, haveDst && haveDport
}
