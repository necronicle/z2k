package main

// dialaddr.go — дозвон до релея БЕЗ участия резолвера.
//
// ЧТО СЛУЧИЛОСЬ. У человека перестал отвечать DNS роутера (127.0.0.1:53,
// dns-proxy прошивки), и телеграм лёг целиком:
//
//	[tunnel] регистрация не удалась: Post "https://213.176.74.63.nip.io/register":
//	dial tcp4: lookup 213.176.74.63.nip.io on 127.0.0.1:53: i/o timeout
//
// Обидное здесь в том, что спрашивать было нечего: nip.io — wildcard-DNS, где
// адрес ЗАПИСАН В САМОМ ИМЕНИ, и ответ резолвера по определению равен первым
// четырём меткам хоста. Мы знали адрес и всё равно шли за ним к резолверу,
// а вместе с ним и умирали. Точно так же ложился второй туннель (:1444,
// cdnbase) — бинарник у них общий.
//
// Имя при этом выбрасывать нельзя: оно нужно для SNI и проверки сертификата
// (сертификат выписан именно на 213.176.74.63.nip.io, см. tests/test_tg_tls_roots.sh).
// Поэтому меняем ТОЛЬКО адрес назначения сокета, а URL и TLS-имя остаются как
// были — ровно тот приём, что curl называет --resolve и который у нас уже
// работает первым хопом в z2k_fetch.
//
// Для любого другого хоста поведение прежнее: штатный резолвер. Если релей
// когда-нибудь переедет за настоящее имя,это правило просто перестанет
// срабатывать, и ничего не сломается.

import (
	"net"
	"strings"
)

// relayDialAddr переводит "a.b.c.d.nip.io:443" в "a.b.c.d:443".
// Любой адрес, не подходящий под это правило, возвращается без изменений.
func relayDialAddr(addr string) string {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	ip := ipFromNipHost(host)
	if ip == "" {
		return addr
	}
	return net.JoinHostPort(ip, port)
}

// ipFromNipHost достаёт литеральный IPv4 из имени вида "1.2.3.4.nip.io".
// Пустая строка — имя не такое, резолвер нужен.
func ipFromNipHost(host string) string {
	h := strings.TrimSuffix(strings.ToLower(host), ".")
	const suffix = ".nip.io"
	if !strings.HasSuffix(h, suffix) {
		return ""
	}
	label := strings.TrimSuffix(h, suffix)
	// Строго четыре метки: "1.2.3.4". Формы с дефисами ("1-2-3-4.nip.io")
	// сознательно не поддерживаем — мы такие не выпускаем, а угадывать
	// чужой формат значит однажды дозвониться не туда.
	if strings.Count(label, ".") != 3 {
		return ""
	}
	ip := net.ParseIP(label)
	if ip == nil || ip.To4() == nil {
		return ""
	}
	return ip.String()
}
