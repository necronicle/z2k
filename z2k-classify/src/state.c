/* z2k-classify — state.tsv manipulation. */
#define _GNU_SOURCE
#include "state.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>

const char *state_path_pick(void) {
	/* Prefer primary; fall back to /tmp only if primary dir missing. */
	struct stat st;
	if (stat("/opt/zapret2/extra_strats/cache/autocircular", &st) == 0) {
		return STATE_FILE_PRIMARY;
	}
	return STATE_FILE_FALLBACK;
}

/* Copy lines from `in` to `out`, DROPPING any row where column 1 ==
 * key && column 2 == host. Returns number of rows dropped. Comments
 * and blank lines are copied as-is. */
static int copy_drop_matching(FILE *in, FILE *out,
                              const char *key, const char *host) {
	char line[2048];
	int dropped = 0;
	while (fgets(line, sizeof(line), in)) {
		if (line[0] == '#' || line[0] == '\n' || line[0] == '\0') {
			fputs(line, out);
			continue;
		}
		/* Parse first two TSV columns. */
		char *tab1 = strchr(line, '\t');
		if (!tab1) { fputs(line, out); continue; }
		char *tab2 = strchr(tab1 + 1, '\t');
		if (!tab2) { fputs(line, out); continue; }

		size_t key_len = (size_t)(tab1 - line);
		size_t host_len = (size_t)(tab2 - (tab1 + 1));

		if (key_len == strlen(key) &&
		    strncmp(line, key, key_len) == 0 &&
		    host_len == strlen(host) &&
		    strncmp(tab1 + 1, host, host_len) == 0) {
			dropped++;
			continue;  /* skip this row — will be re-written by caller */
		}
		fputs(line, out);
	}
	return dropped;
}

/* Atomic replace of dest with tmp (on same filesystem). */
static int atomic_replace(const char *dest, const char *tmp) {
	if (rename(tmp, dest) != 0) {
		unlink(tmp);
		return -1;
	}
	return 0;
}

int state_pin(const char *state_path, const char *key, const char *host,
              int strategy_num) {
	char tmp_path[256];
	snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%d", state_path, (int)getpid());

	FILE *out = fopen(tmp_path, "w");
	if (!out) return -1;

	FILE *in = fopen(state_path, "r");
	if (in) {
		/* Write header if the file is brand new or starts without one. */
		copy_drop_matching(in, out, key, host);
		fclose(in);
	} else {
		/* First-time creation — write canonical header. */
		fputs("# z2k autocircular state (persisted circular nstrategy)\n", out);
		fputs("# key\thost\tstrategy\tts\n", out);
	}

	/* Append our row. */
	fprintf(out, "%s\t%s\t%d\t%ld\n", key, host, strategy_num, (long)time(NULL));

	if (fflush(out) != 0 || fsync(fileno(out)) != 0) {
		fclose(out);
		unlink(tmp_path);
		return -1;
	}
	fclose(out);

	/* chmod to match typical autocircular file perms (0644). */
	chmod(tmp_path, 0644);

	return atomic_replace(state_path, tmp_path);
}

int state_unpin(const char *state_path, const char *key, const char *host) {
	char tmp_path[256];
	snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%d", state_path, (int)getpid());

	FILE *in = fopen(state_path, "r");
	if (!in) return 0;  /* nothing to unpin */

	FILE *out = fopen(tmp_path, "w");
	if (!out) { fclose(in); return -1; }

	copy_drop_matching(in, out, key, host);

	fclose(in);
	fflush(out);
	fsync(fileno(out));
	fclose(out);
	chmod(tmp_path, 0644);

	return atomic_replace(state_path, tmp_path);
}
