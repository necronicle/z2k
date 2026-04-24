/* z2k-classify — active probe sequence.
 *
 * Phase 1 implementation uses standard POSIX sockets + getsockopt
 * (TCP_INFO) + inline TLS ClientHello. No raw AF_PACKET capture yet —
 * that's a Phase 2 upgrade when we need to see DPI-injected packets
 * distinctly from server-generated ones.
 *
 * Symptom matrix collected:
 *   dns_ok                — getaddrinfo success
 *   icmp_reachable        — single ICMP echo to dst (best-effort,
 *                           false if non-root / ICMP filtered)
 *   tcp_connect_ok        — connect() to :443 within 5 s
 *   tls_handshake_ok      — completed ClientHello/ServerHello exchange
 *   server_ts_negotiated  — TCP TS option echoed (matters for AWS)
 *   size_before_stall     — bytes received before recv() stalls/errors
 *   size_final            — total bytes read
 *   server_rst_received   — EPIPE/ECONNRESET during read
 *   rst_after_bytes       — offset of the RST (0 if during handshake)
 */
#define _GNU_SOURCE
#include "probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <poll.h>

/* ICMP header: use a plain struct to avoid platform header divergence
 * (Linux <linux/icmp.h> uses `struct icmphdr`, BSD/macOS uses `struct
 * icmp` with different field layout). We only need echo-request, which
 * is the same 8-byte wire format on all POSIX. */
#define Z2K_ICMP_ECHO 8
struct z2k_icmphdr {
	uint8_t  type;
	uint8_t  code;
	uint16_t checksum;
	uint16_t id;
	uint16_t seq;
};

/* ---- helpers ---- */

static int64_t now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Build a minimal TLS 1.2 ClientHello with SNI = sni_host.
 * Not a real Chrome fingerprint — enough to trigger DPI SNI inspection
 * for probing. Returns bytes written into buf. buf must hold ≥ 512. */
static size_t build_client_hello(char *buf, size_t buflen, const char *sni_host) {
	size_t sni_len = strlen(sni_host);
	if (sni_len > 253) return 0;
	if (buflen < 512) return 0;

	/* Fixed section — 32B random is zero-filled, DPI cares only about
	 * structure + SNI, not entropy. */
	unsigned char body[512];
	size_t p = 0;
	/* Handshake: ClientHello */
	body[p++] = 0x01;  /* type: ClientHello */
	size_t hs_len_off = p; p += 3;  /* 3-byte length, fill later */
	/* Version TLS 1.2 */
	body[p++] = 0x03; body[p++] = 0x03;
	/* 32 random bytes */
	memset(&body[p], 0x5a, 32); p += 32;
	/* Session ID length 0 */
	body[p++] = 0x00;
	/* Cipher suites length (2B), then suites. One suite: TLS_AES_128_GCM_SHA256 (0x1301). */
	body[p++] = 0x00; body[p++] = 0x02;
	body[p++] = 0x13; body[p++] = 0x01;
	/* Compression methods length (1B), then methods: null */
	body[p++] = 0x01; body[p++] = 0x00;

	/* Extensions */
	size_t ext_len_off = p; p += 2;  /* 2-byte total length */
	size_t ext_start = p;
	/* server_name extension (type 0x0000) */
	body[p++] = 0x00; body[p++] = 0x00;           /* type */
	body[p++] = 0x00; body[p++] = (unsigned char)(sni_len + 5);  /* ext data len */
	body[p++] = 0x00; body[p++] = (unsigned char)(sni_len + 3);  /* SNI list len */
	body[p++] = 0x00;                             /* name type: hostname */
	body[p++] = 0x00; body[p++] = (unsigned char)sni_len;        /* hostname len */
	memcpy(&body[p], sni_host, sni_len); p += sni_len;

	/* supported_versions: TLS 1.2 only for broad compat */
	body[p++] = 0x00; body[p++] = 0x2b; /* type 0x002b */
	body[p++] = 0x00; body[p++] = 0x03;
	body[p++] = 0x02; body[p++] = 0x03; body[p++] = 0x03;

	size_t ext_len = p - ext_start;
	body[ext_len_off] = (unsigned char)(ext_len >> 8);
	body[ext_len_off + 1] = (unsigned char)(ext_len & 0xff);

	size_t hs_len = p - hs_len_off - 3;
	body[hs_len_off]     = 0x00;
	body[hs_len_off + 1] = (unsigned char)(hs_len >> 8);
	body[hs_len_off + 2] = (unsigned char)(hs_len & 0xff);

	/* Wrap in TLS record: type 0x16 (handshake), version 0x0303, len */
	buf[0] = 0x16;
	buf[1] = 0x03; buf[2] = 0x01;   /* record version TLS 1.0 (historical) */
	buf[3] = (char)(p >> 8);
	buf[4] = (char)(p & 0xff);
	memcpy(&buf[5], body, p);
	return p + 5;
}

/* Connect with timeout. Returns fd on success, -1 on failure. */
static int connect_tcp_timeout(struct in_addr ip, int port, int timeout_ms,
                               bool *connected, int *last_errno) {
	*connected = false;
	*last_errno = 0;

	int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) { *last_errno = errno; return -1; }

	int fl = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, fl | O_NONBLOCK);

	struct sockaddr_in sa = {0};
	sa.sin_family = AF_INET;
	sa.sin_port = htons(port);
	sa.sin_addr = ip;

	int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
	if (rc == 0) {
		*connected = true;
		fcntl(fd, F_SETFL, fl);  /* back to blocking */
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
	fcntl(fd, F_SETFL, fl);  /* back to blocking */
	return fd;
}

/* Set SO_RCVTIMEO / SO_SNDTIMEO on fd. */
static void set_socket_timeout(int fd, int ms) {
	struct timeval tv = { .tv_sec = ms / 1000, .tv_usec = (ms % 1000) * 1000 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

/* Check TCP_INFO to see if server negotiated TS option. On Linux,
 * tcpi_options & TCPI_OPT_TIMESTAMPS is set when server's SYN-ACK
 * carried the TS option. */
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

/* ---- subprobes ---- */

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
	/* Non-root best-effort: try SOCK_DGRAM ICMP (Linux feature), fall
	 * back to silent false. We're running on router as root so real
	 * SOCK_RAW should also work. */
	int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
	if (fd < 0) {
		fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
		if (fd < 0) return false;
	}
	set_socket_timeout(fd, 2000);

	struct {
		struct z2k_icmphdr h;
		char pad[8];
	} pkt = {0};
	pkt.h.type = Z2K_ICMP_ECHO;
	pkt.h.id = htons((uint16_t)getpid());
	pkt.h.seq = htons(1);
	/* Checksum is filled by kernel for SOCK_DGRAM ICMP on Linux. For
	 * SOCK_RAW we'd need to compute it here; Phase 1 accepts best-
	 * effort (SOCK_DGRAM path). */

	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr = ip };
	if (sendto(fd, &pkt, sizeof(pkt), 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return false;
	}
	char buf[128];
	ssize_t n = recv(fd, buf, sizeof(buf), 0);
	close(fd);
	return n > 0;
}

/* ---- main entry ---- */

int probe_run(const char *domain, int timeout_sec, probe_result_t *out,
              struct in_addr *resolved_ip) {
	memset(out, 0, sizeof(*out));
	int64_t t0 = now_ms();

	out->dns_ok = subprobe_dns(domain, resolved_ip);
	if (!out->dns_ok) {
		out->duration_ms = (int)(now_ms() - t0);
		return 0;
	}

	out->icmp_reachable = subprobe_icmp(*resolved_ip);

	/* TCP connect with 5 s timeout. */
	bool connected; int cerr;
	int fd = connect_tcp_timeout(*resolved_ip, 443, 5000, &connected, &cerr);
	out->tcp_connect_ok = connected;
	if (!connected) {
		out->duration_ms = (int)(now_ms() - t0);
		return 0;
	}

	out->server_ts_negotiated = server_negotiated_ts(fd);

	/* Send ClientHello with SNI = domain itself. */
	char ch[1024];
	size_t ch_len = build_client_hello(ch, sizeof(ch), domain);
	if (ch_len == 0) { close(fd); out->duration_ms = (int)(now_ms() - t0); return -1; }

	set_socket_timeout(fd, 3000);
	ssize_t sent = send(fd, ch, ch_len, 0);
	if (sent < 0) {
		/* EPIPE here = RST right after SYN-ACK before CH data. Unusual
		 * but possible. */
		out->server_rst_received = (errno == EPIPE || errno == ECONNRESET);
		out->rst_after_bytes = 0;
		close(fd);
		out->duration_ms = (int)(now_ms() - t0);
		return 0;
	}

	/* Read loop — collect up to 64 KB, note when flow stalls or RSTs. */
	char rx[65536];
	size_t total = 0;
	bool stalled_at_16kb = false;
	int64_t t_first_byte = 0;
	while (total < sizeof(rx)) {
		ssize_t n = recv(fd, rx + total, sizeof(rx) - total, 0);
		if (n == 0) break;  /* orderly close */
		if (n < 0) {
			if (errno == ECONNRESET) {
				out->server_rst_received = true;
				out->rst_after_bytes = (int)total;
			}
			break;
		}
		if (t_first_byte == 0) t_first_byte = now_ms();
		total += n;

		/* Heuristic: if we've been at the 15-17 KB window for ≥1 s
		 * without progress, it's the TSPU throttle signature. */
		if (total >= 15000 && total <= 17000) {
			int64_t t = now_ms();
			/* peek once more with short timeout to confirm stall */
			set_socket_timeout(fd, 1500);
			ssize_t m = recv(fd, rx + total, sizeof(rx) - total, 0);
			if (m <= 0) { stalled_at_16kb = true; break; }
			total += m;
			set_socket_timeout(fd, 3000);
			(void)t;
		}
	}
	out->size_final = (uint32_t)total;
	out->size_before_stall = stalled_at_16kb ? (uint32_t)total : 0;
	out->tls_handshake_ok = total > 0;  /* got at least the ServerHello */

	close(fd);
	(void)timeout_sec;  /* Phase 1: per-probe timeouts hardcoded; total budget wraps caller */
	out->duration_ms = (int)(now_ms() - t0);
	return 0;
}
