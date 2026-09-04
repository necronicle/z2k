//go:build linux

package voiceprobe

import (
	"os"
	"path/filepath"
	"testing"
)

// Разбор conntrack проверяется на настоящих строках ядра: формат отличается
// началом (колонка семейства есть не везде), и разбор по номерам полей на
// одном роутере работал бы, а на другом молча брал бы не тот адрес.
func TestFindVoiceTargetsPicksLiveCall(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nf_conntrack")
	// Строки: голосовой поток с 900 пакетами, второй голосовой послабее,
	// обычный QUIC на 443 (не голос), поток на приватный адрес (не наружу),
	// и TCP (не наш протокол).
	content := `ipv4     2 udp      17 29 src=192.168.1.67 dst=66.22.196.1 sport=51234 dport=50012 packets=900 bytes=120000 src=66.22.196.1 dst=88.87.93.11 sport=50012 dport=51234 packets=880 bytes=110000 mark=0 use=1
ipv4     2 udp      17 29 src=192.168.1.67 dst=66.22.197.9 sport=51235 dport=3478 packets=12 bytes=1400 src=66.22.197.9 dst=88.87.93.11 sport=3478 dport=51235 packets=10 bytes=1200 mark=0 use=1
ipv4     2 udp      17 29 src=192.168.1.67 dst=142.251.1.1 sport=51236 dport=443 packets=500 bytes=60000 mark=0 use=1
ipv4     2 udp      17 29 src=192.168.1.67 dst=192.168.1.90 sport=51237 dport=50020 packets=99 bytes=9000 mark=0 use=1
ipv4     2 tcp      6 431999 ESTABLISHED src=192.168.1.67 dst=1.2.3.4 sport=40000 dport=50010 packets=5 bytes=500 mark=0 use=1
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	old := ConntrackPath
	ConntrackPath = path
	defer func() { ConntrackPath = old }()

	got, err := FindVoiceTargets()
	if err != nil {
		t.Fatalf("FindVoiceTargets: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("найдено %d целей, ожидалось 2: %+v", len(got), got)
	}
	// Первым обязан идти самый нагруженный: это и есть текущий разговор.
	if got[0].IP.String() != "66.22.196.1" || got[0].Port != 50012 {
		t.Errorf("первая цель %s, ожидалась 66.22.196.1:50012", got[0])
	}
	if got[0].Packets < got[1].Packets {
		t.Error("цели не отсортированы по числу пакетов")
	}
	for _, g := range got {
		if g.Port == 443 {
			t.Error("обычный QUIC на 443 принят за голос")
		}
		if g.IP.IsPrivate() {
			t.Error("поток на приватный адрес принят за голос")
		}
	}
}

// Нет таблицы — это ошибка, а не «разговора нет». Пустой список отправил бы
// человека искать проблему в Дискорде.
func TestMissingConntrackIsAnError(t *testing.T) {
	old := ConntrackPath
	ConntrackPath = filepath.Join(t.TempDir(), "нет-такого")
	defer func() { ConntrackPath = old }()

	if _, err := FindVoiceTargets(); err == nil {
		t.Fatal("отсутствие таблицы соединений не считается ошибкой")
	}
}

// Диапазоны портов обязаны совпадать с боевым профилем: разъедутся — зонд
// начнёт мерить не тот трафик, который обходит движок.
func TestVoicePortRanges(t *testing.T) {
	for _, p := range []int{50000, 50050, 50100, 1400, 3478, 3481, 5349, 19294, 19344} {
		if !isVoicePort(p) {
			t.Errorf("порт %d не признан голосовым", p)
		}
	}
	for _, p := range []int{443, 80, 49999, 50101, 3477, 3482, 19293, 19345} {
		if isVoicePort(p) {
			t.Errorf("порт %d ошибочно признан голосовым", p)
		}
	}
}
