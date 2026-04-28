/* z2k-classify — active probe.
 *
 * POSIX sockets + inline TLS ClientHello (no real key exchange).
 * Probe captures: dns/icmp/tcp_connect/tls_response/server_ts/rst/stall.
 *
 * Multi-replica wrapper runs probe_run_replica() N times with small
 * inter-probe gap. Surfaces probabilistic RST patterns that single-shot
 * miscalls (e.g. МГТС cloudflare).
 */
#define _GNU_SOURCE
#include "probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#ifdef __linux__
#include <netinet/ip_icmp.h>
#endif
#include <poll.h>

/* Random bytes for ClientHello randomness fields. /dev/urandom is
 * available on every kernel we run on (Entware Linux ≥ 3.x, glibc/musl
 * userland). On open/read failure we fall back to a deterministic
 * pseudo-pattern so the probe still produces *some* output rather
 * than refusing to run; the deterministic path is the legacy behavior
 * before this fix landed. */
static void z2k_random_bytes(unsigned char *buf, size_t n) {
	int fd = open("/dev/urandom", O_RDONLY);
	if (fd >= 0) {
		ssize_t total = 0;
		while ((size_t)total < n) {
			ssize_t r = read(fd, buf + total, n - total);
			if (r <= 0) break;
			total += r;
		}
		close(fd);
		if ((size_t)total == n) return;
	}
	static unsigned int ctr = 0;
	for (size_t i = 0; i < n; i++)
		buf[i] = (unsigned char)((ctr++ * 17 + 41) & 0xff);
}

static int64_t now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void sleep_ms(int ms) {
	struct timespec ts = { .tv_sec = ms / 1000,
	                       .tv_nsec = (ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

/* Build minimal but well-formed TLS ClientHello with given SNI. */
static size_t build_client_hello(char *buf, size_t buflen, const char *sni_host) {
	size_t sni_len = strlen(sni_host);
	if (sni_len > 253 || buflen < 1024) return 0;

	unsigned char body[1024];
	size_t p = 0;

	body[p++] = 0x01;
	size_t hs_len_off = p; p += 3;
	body[p++] = 0x03; body[p++] = 0x03;
	z2k_random_bytes(&body[p], 32); p += 32;
	body[p++] = 0x20;
	z2k_random_bytes(&body[p], 32); p += 32;

	static const unsigned char suites[] = {
		0xc0,0x2b, 0xc0,0x2f, 0xc0,0x2c, 0xc0,0x30,
		0xcc,0xa9, 0xcc,0xa8,
		0xc0,0x13, 0xc0,0x14,
		0xc0,0x09, 0xc0,0x0a,
		0x00,0x9c, 0x00,0x9d,
		0x00,0x2f, 0x00,0x35,
		0x00,0x0a,
	};
	size_t sl = sizeof(suites);
	body[p++] = (unsigned char)(sl >> 8); body[p++] = (unsigned char)(sl & 0xff);
	memcpy(&body[p], suites, sl); p += sl;

	body[p++] = 0x01; body[p++] = 0x00;

	size_t ext_len_off = p; p += 2;
	size_t ext_start = p;

	body[p++] = 0x00; body[p++] = 0x00;
	body[p++] = 0x00; body[p++] = (unsigned char)(sni_len + 5);
	body[p++] = 0x00; body[p++] = (unsigned char)(sni_len + 3);
	body[p++] = 0x00;
	body[p++] = 0x00; body[p++] = (unsigned char)sni_len;
	memcpy(&body[p], sni_host, sni_len); p += sni_len;

	body[p++] = 0x00; body[p++] = 0x0b;
	body[p++] = 0x00; body[p++] = 0x02;
	body[p++] = 0x01; body[p++] = 0x00;

	body[p++] = 0x00; body[p++] = 0x0a;
	body[p++] = 0x00; body[p++] = 0x08;
	body[p++] = 0x00; body[p++] = 0x06;
	body[p++] = 0x00; body[p++] = 0x1d;
	body[p++] = 0x00; body[p++] = 0x17;
	body[p++] = 0x00; body[p++] = 0x18;

	static const unsigned char sigalgs[] = {
		0x04,0x03, 0x05,0x03, 0x08,0x07,
		0x08,0x04, 0x08,0x05, 0x08,0x06,
		0x04,0x01, 0x05,0x01, 0x06,0x01,
	};
	size_t sa = sizeof(sigalgs);
	body[p++] = 0x00; body[p++] = 0x0d;
	body[p++] = (unsigned char)((sa + 2) >> 8);
	body[p++] = (unsigned char)((sa + 2) & 0xff);
	body[p++] = (unsigned char)(sa >> 8);
	body[p++] = (unsigned char)(sa & 0xff);
	memcpy(&body[p], sigalgs, sa); p += sa;

	body[p++] = 0x00; body[p++] = 0x10;
	body[p++] = 0x00; body[p++] = 0x0e;
	body[p++] = 0x00; body[p++] = 0x0c;
	body[p++] = 0x02; body[p++] = 'h'; body[p++] = '2';
	body[p++] = 0x08; body[p++] = 'h'; body[p++] = 't'; body[p++] = 't'; body[p++] = 'p';
	body[p++] = '/'; body[p++] = '1'; body[p++] = '.'; body[p++] = '1';

	body[p++] = 0x00; body[p++] = 0x17;
	body[p++] = 0x00; body[p++] = 0x00;

	body[p++] = 0xff; body[p++] = 0x01;
	body[p++] = 0x00; body[p++] = 0x01;
	body[p++] = 0x00;

	size_t ext_len = p - ext_start;
	body[ext_len_off]     = (unsigned char)(ext_len >> 8);
	body[ext_len_off + 1] = (unsigned char)(ext_len & 0xff);

	size_t hs_len = p - hs_len_off - 3;
	body[hs_len_off]     = 0x00;
	body[hs_len_off + 1] = (unsigned char)(hs_len >> 8);
	body[hs_len_off + 2] = (unsigned char)(hs_len & 0xff);

	buf[0] = 0x16;
	buf[1] = 0x03; buf[2] = 0x01;
	buf[3] = (char)(p >> 8);
	buf[4] = (char)(p & 0xff);
	memcpy(&buf[5], body, p);
	return p + 5;
}

#define NFQWS2_FWMARK 0x40000000u

static int connect_tcp_timeout(struct in_addr ip, int port, int timeout_ms,
                               bool *connected, int *last_errno,
                               bool raw_bypass) {
	*connected = false;
	*last_errno = 0;

	int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) { *last_errno = errno; return -1; }

#ifdef SO_MARK
	if (raw_bypass) {
		unsigned mark = NFQWS2_FWMARK;
		(void)setsockopt(fd, SOL_SOCKET, SO_MARK, &mark, sizeof(mark));
	}
#else
	(void)raw_bypass;
#endif

	int fl = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, fl | O_NONBLOCK);

	struct sockaddr_in sa = {0};
	sa.sin_family = AF_INET;
	sa.sin_port = htons(port);
	sa.sin_addr = ip;

	int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
	if (rc == 0) {
		*connected = true;
		fcntl(fd, F_SETFL, fl);
		return fd;
	}
	if (errno != EINPROGRESS) {
		*last_errno = errno;
		close(fd);
		return -1;
	}

	struct pollfd pf = { .fd = fd, .events = POLLOUT };
	rc = poll(&pf, 1, timeout_ms);
	if (rc <= 0) {
		*last_errno = (rc == 0) ? ETIMEDOUT : errno;
		close(fd);
		return -1;
	}

	int so_err = 0;
	socklen_t len = sizeof(so_err);
	getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &len);
	if (so_err != 0) {
		*last_errno = so_err;
		close(fd);
		return -1;
	}

	*connected = true;
	fcntl(fd, F_SETFL, fl);
	return fd;
}

static void set_socket_timeout(int fd, int ms) {
	struct timeval tv = { .tv_sec = ms / 1000, .tv_usec = (ms % 1000) * 1000 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static bool server_negotiated_ts(int fd) {
#ifdef TCP_INFO
	struct tcp_info ti;
	socklen_t len = sizeof(ti);
	if (getsockopt(fd, IPPROTO_TCP, TCP_INFO, &ti, &len) != 0) return false;
#ifdef TCPI_OPT_TIMESTAMPS
	return (ti.tcpi_options & TCPI_OPT_TIMESTAMPS) != 0;
#else
	return false;
#endif
#else
	(void)fd;
	return false;
#endif
}

/* Server's MSS as reported by TCP_INFO. Phase-1 best-effort proxy for
 * "is server in slow-start mode?" — full SYN-ACK advertised window
 * needs raw capture to read accurately. We use snd_mss < 1200 as a
 * heuristic (many anti-DDoS frontends advertise tiny MSS to slow the
 * client). Real check would compare advertised cwnd. */
static uint32_t server_initial_winsize_proxy(int fd) {
#ifdef TCP_INFO
	struct tcp_info ti;
	socklen_t len = sizeof(ti);
	if (getsockopt(fd, IPPROTO_TCP, TCP_INFO, &ti, &len) != 0) return 0;
	return (uint32_t)ti.tcpi_snd_mss;
#else
	(void)fd;
	return 0;
#endif
}

static bool subprobe_dns(const char *domain, struct in_addr *out_ip) {
	struct addrinfo hints = {0}, *res = NULL;
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	if (getaddrinfo(domain, NULL, &hints, &res) != 0 || !res) return false;
	*out_ip = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
	freeaddrinfo(res);
	return true;
}

static bool subprobe_icmp(struct in_addr ip) {
#ifdef __linux__
	int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
	if (fd < 0) {
		fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
		if (fd < 0) return false;
	}
	set_socket_timeout(fd, 2000);

	struct {
		struct icmphdr h;
		char pad[8];
	} pkt = {0};
	pkt.h.type = ICMP_ECHO;
	pkt.h.un.echo.id = htons((uint16_t)getpid());
	pkt.h.un.echo.sequence = htons(1);

	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr = ip };
	if (sendto(fd, &pkt, sizeof(pkt), 0,
	            (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return false;
	}
	char buf[128];
	ssize_t n = recv(fd, buf, sizeof(buf), 0);
	close(fd);
	return n > 0;
#else
	(void)ip;
	return false;
#endif
}

int probe_run_replica(const char *domain, int timeout_sec,
                      probe_replica_t *out, struct in_addr *resolved_ip,
                      bool raw_bypass) {
	memset(out, 0, sizeof(*out));
	int64_t t0 = now_ms();

	out->dns_ok = subprobe_dns(domain, resolved_ip);
	if (!out->dns_ok) {
		out->duration_ms = (int)(now_ms() - t0);
		return 0;
	}

	out->icmp_reachable = subprobe_icmp(*resolved_ip);

	bool connected; int cerr;
	int fd = connect_tcp_timeout(*resolved_ip, 443, 5000, &connected, &cerr,
	                              raw_bypass);
	out->tcp_connect_ok = connected;
	if (!connected) {
		out->duration_ms = (int)(now_ms() - t0);
		return 0;
	}

	out->server_ts_negotiated = server_negotiated_ts(fd);
	out->server_initial_winsize = server_initial_winsize_proxy(fd);

	char ch[1024];
	size_t ch_len = build_client_hello(ch, sizeof(ch), domain);
	if (ch_len == 0) {
		close(fd);
		out->duration_ms = (int)(now_ms() - t0);
		return -1;
	}

	set_socket_timeout(fd, 3000);
	ssize_t sent = send(fd, ch, ch_len, 0);
	if (sent < 0) {
		out->server_rst_received = (errno == EPIPE || errno == ECONNRESET);
		out->rst_after_bytes = 0;
		close(fd);
		out->duration_ms = (int)(now_ms() - t0);
		return 0;
	}

	char rx[65536];
	size_t total = 0;
	bool stalled_at_16kb = false;
	bool crossed_15k = false;
	int64_t t_first = 0;
	while (total < sizeof(rx)) {
		ssize_t n = recv(fd, rx + total, sizeof(rx) - total, 0);
		if (n == 0) break;
		if (n < 0) {
			if (errno == ECONNRESET) {
				out->server_rst_received = true;
				out->rst_after_bytes = (int)total;
			}
			break;
		}
		if (t_first == 0) t_first = now_ms();
		size_t prev_total = total;
		total += n;

		/* Trigger the 16KB-stall probe the moment cumulative size
		 * crosses 15000, regardless of recv() chunking. A single
		 * recv that returns 18000 bytes used to skip the old
		 * range-membership check entirely. */
		if (!crossed_15k && prev_total < 15000 && total >= 15000) {
			crossed_15k = true;
			set_socket_timeout(fd, 1500);
			ssize_t m = recv(fd, rx + total, sizeof(rx) - total, 0);
			if (m <= 0) { stalled_at_16kb = true; break; }
			total += m;
			set_socket_timeout(fd, 3000);
		}
	}
	out->size_final = (uint32_t)total;
	out->size_before_stall = stalled_at_16kb ? (uint32_t)total : 0;
	out->tls_handshake_ok = total > 0;

	close(fd);
	(void)timeout_sec;
	out->duration_ms = (int)(now_ms() - t0);
	return 0;
}

int probe_run(const char *domain, int timeout_sec, int replicas,
              probe_aggregate_t *agg, struct in_addr *resolved_ip,
              bool raw_bypass) {
	if (replicas <= 0) replicas = 3;
	if (replicas > PROBE_REPLICAS_MAX) replicas = PROBE_REPLICAS_MAX;

	memset(agg, 0, sizeof(*agg));
	agg->replica_count = replicas;

	struct in_addr ip = {0};
	for (int i = 0; i < replicas; i++) {
		int rc = probe_run_replica(domain, timeout_sec, &agg->replicas[i],
		                            &ip, raw_bypass);
		if (rc < 0) return rc;
		if (i + 1 < replicas) sleep_ms(400 + (i * 150));
	}
	*resolved_ip = ip;
	return 0;
}

/* ---- traceroute subprobe ---- */

#define TRACEROUTE_BIN "/opt/bin/traceroute"

/* ISP suffix → name. Last entry { NULL, NULL } sentinel. */
static const struct {
	const char *suffix;
	const char *name;
} g_isp_suffixes[] = {
	{ "mts-internet.net", "МТС" },
	{ "mgts.ru",          "МГТС" },
	{ "umt.ru",           "МТС" },
	{ ".rt.ru",           "Ростелеком" },
	{ "rostelecom",       "Ростелеком" },
	{ "tmpu",             "Ростелеком" },
	{ "beeline.ru",       "Билайн" },
	{ "corbina.net",      "Билайн (Corbina)" },
	{ "comcor",           "Билайн (Corbina)" },
	{ "domru.ru",         "Дом.ру" },
	{ "ertelecom",        "Дом.ру (ЭР-Телеком)" },
	{ "tele2.ru",         "T2" },
	{ "t2ru.ru",          "T2" },
	{ "megafon.ru",       "МегаФон" },
	{ "metrocom",         "МегаФон" },
	{ "intersvyaz",       "Интерсвязь" },
	{ "novotelecom",      "Новотелеком" },
	{ "freedom",          "Freedom" },
	{ NULL, NULL }
};

static const char *isp_for_revdns(const char *revdns) {
	if (!revdns || !*revdns) return "";
	for (int i = 0; g_isp_suffixes[i].suffix; i++) {
		if (strstr(revdns, g_isp_suffixes[i].suffix)) {
			return g_isp_suffixes[i].name;
		}
	}
	return "";
}

/* Parse one traceroute output line, e.g.:
 *   " 6  mag9-cr03-be12.51.msk.mts-internet.net (212.188.6.44)  11.000 ms"
 *   " 5  *"
 *   " 4  10.109.11.125 (10.109.11.125)  8.000 ms"
 * Output: ttl, host_or_star, ip4. Returns 1 on success, 0 if not a hop
 * line, -1 on parse error.
 */
static int parse_trace_line(const char *line, int *out_ttl,
                            char *out_host, size_t hostsz,
                            struct in_addr *out_ip, bool *out_responded) {
	while (*line == ' ' || *line == '\t') line++;
	if (!isdigit((unsigned char)*line)) return 0;

	int ttl = 0;
	while (isdigit((unsigned char)*line)) {
		ttl = ttl * 10 + (*line - '0');
		line++;
	}
	*out_ttl = ttl;

	while (*line == ' ' || *line == '\t') line++;
	if (*line == '*') {
		*out_responded = false;
		out_host[0] = '\0';
		out_ip->s_addr = 0;
		return 1;
	}

	/* Could be "host (ip)" or just "ip". Find '(' for the parenthesized form. */
	const char *paren = strchr(line, '(');
	const char *end_paren = paren ? strchr(paren, ')') : NULL;

	if (paren && end_paren && end_paren > paren + 1) {
		size_t name_len = (size_t)(paren - line);
		while (name_len > 0 && (line[name_len - 1] == ' ' ||
		                        line[name_len - 1] == '\t')) name_len--;
		if (name_len >= hostsz) name_len = hostsz - 1;
		memcpy(out_host, line, name_len);
		out_host[name_len] = '\0';

		char ipbuf[64];
		size_t ip_len = (size_t)(end_paren - paren - 1);
		if (ip_len >= sizeof(ipbuf)) ip_len = sizeof(ipbuf) - 1;
		memcpy(ipbuf, paren + 1, ip_len);
		ipbuf[ip_len] = '\0';
		if (inet_aton(ipbuf, out_ip) == 0) {
			out_ip->s_addr = 0;
			*out_responded = false;
			return 1;
		}
	} else {
		/* Bare IP form. */
		char ipbuf[64];
		size_t i = 0;
		while (line[i] && line[i] != ' ' && line[i] != '\t' &&
		       i + 1 < sizeof(ipbuf)) {
			ipbuf[i] = line[i]; i++;
		}
		ipbuf[i] = '\0';
		if (inet_aton(ipbuf, out_ip) == 0) {
			out_ip->s_addr = 0;
			out_host[0] = '\0';
			*out_responded = false;
			return 1;
		}
		snprintf(out_host, hostsz, "%s", ipbuf);
	}
	*out_responded = true;
	return 1;
}

/* Reverse-DNS the last live hop. Tries getnameinfo first, falls back
 * to spawning `nslookup` because static-musl resolver behavior varies
 * and we already depend on busybox utils for traceroute. */
static void revdns_lookup(struct in_addr ip, char *out, size_t outsz) {
	out[0] = '\0';

	struct sockaddr_in sa = {0};
	sa.sin_family = AF_INET;
	sa.sin_addr = ip;
	if (getnameinfo((struct sockaddr *)&sa, sizeof(sa),
	                out, (socklen_t)outsz, NULL, 0,
	                NI_NAMEREQD) == 0 && out[0]) {
		return;
	}
	out[0] = '\0';

	/* Fallback: spawn nslookup. Output (busybox):
	 *   Server:    127.0.0.1
	 *   ...
	 *   Name:      88.87.67.34
	 *   Address 1: 88.87.67.34 lag-7-435.bbr01.voronezh.ertelecom.ru
	 * We grep for the last "Address" line and extract the trailing host. */
	char ipbuf[INET_ADDRSTRLEN];
	if (!inet_ntop(AF_INET, &ip, ipbuf, sizeof(ipbuf))) return;
	char cmd[128];
	snprintf(cmd, sizeof(cmd), "nslookup %s 2>/dev/null", ipbuf);
	FILE *fp = popen(cmd, "r");
	if (!fp) return;
	char line[512];
	while (fgets(line, sizeof(line), fp)) {
		/* Expected fragment: "Address[ N]:[space]IP[space]NAME" — pull
		 * the last whitespace-separated token if it's not the IP. */
		if (strncmp(line, "Address", 7) != 0) continue;
		const char *colon = strchr(line, ':');
		if (!colon) continue;
		const char *p = colon + 1;
		while (*p == ' ' || *p == '\t') p++;
		/* skip the IP and following whitespace */
		while (*p && *p != ' ' && *p != '\t' && *p != '\n') p++;
		while (*p == ' ' || *p == '\t') p++;
		if (!*p || *p == '\n') continue;
		size_t n = 0;
		while (p[n] && p[n] != ' ' && p[n] != '\t' &&
		       p[n] != '\n' && n + 1 < outsz) {
			out[n] = p[n]; n++;
		}
		out[n] = '\0';
		if (n > 0) break;
	}
	pclose(fp);
}

int probe_trace_path(struct in_addr dest, probe_aggregate_t *agg) {
	struct stat st;
	if (stat(TRACEROUTE_BIN, &st) != 0) {
		agg->trace_attempted = false;
		return 0;
	}
	agg->trace_attempted = true;

	char ipbuf[INET_ADDRSTRLEN];
	if (!inet_ntop(AF_INET, &dest, ipbuf, sizeof(ipbuf))) return -1;

	char cmd[256];
	snprintf(cmd, sizeof(cmd),
	         TRACEROUTE_BIN " -n -m %d -w 2 -q 1 %s 2>/dev/null",
	         TRACE_MAX_HOPS, ipbuf);

	FILE *fp = popen(cmd, "r");
	if (!fp) return -1;

	char line[1024];
	int max_ttl = 0;
	int last_live = 0;
	struct in_addr last_live_ip = {0};
	bool reaches_dest = false;
	while (fgets(line, sizeof(line), fp)) {
		int ttl = 0;
		char host[128] = {0};
		struct in_addr hip = {0};
		bool responded = false;
		int rc = parse_trace_line(line, &ttl, host, sizeof(host),
		                           &hip, &responded);
		if (rc != 1) continue;
		if (ttl < 1 || ttl > TRACE_MAX_HOPS) continue;
		max_ttl = (ttl > max_ttl) ? ttl : max_ttl;
		trace_hop_t *h = &agg->trace_hops[ttl - 1];
		h->ip = hip;
		h->responded = responded;
		if (responded) {
			last_live = ttl;
			last_live_ip = hip;
			if (host[0]) snprintf(h->revdns, sizeof(h->revdns), "%s", host);
			if (hip.s_addr == dest.s_addr) {
				reaches_dest = true;
			}
		}
	}
	pclose(fp);

	agg->trace_max_ttl_tried = max_ttl;
	agg->trace_last_live_ttl = last_live;
	agg->trace_reaches_dest = reaches_dest;
	agg->trace_last_live_ip = last_live_ip;

	if (last_live > 0) {
		/* Resolve last hop's revdns properly via getnameinfo if -n
		 * suppressed it. */
		revdns_lookup(last_live_ip, agg->trace_last_revdns,
		              sizeof(agg->trace_last_revdns));
		const char *isp = isp_for_revdns(agg->trace_last_revdns);
		snprintf(agg->trace_isp_name, sizeof(agg->trace_isp_name),
		         "%s", isp ? isp : "");
	}

	return 0;
}
