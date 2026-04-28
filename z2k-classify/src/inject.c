/* z2k-classify — runtime strategy injection.
 *
 * The actual sed/awk/regen/restart work is delegated to a small shell
 * script (`z2k-classify-inject` helper) which knows the strats_new2.txt
 * format and the regen+restart machinery. This C side just calls it.
 * Keeping the file-rewrite logic in shell lets us reuse the exact
 * patterns the rest of z2k uses (avoids drift between C string-edit
 * and shell preprocessor expectations).
 */
#define _GNU_SOURCE
#include "inject.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>

#define HELPER_PATH "/opt/zapret2/z2k-classify-inject.sh"

/* Run helper script with arguments. Returns helper's exit code, or
 * -1 if execvp itself failed. */
static int run_helper(const char *const argv[]) {
	pid_t pid = fork();
	if (pid < 0) return -1;
	if (pid == 0) {
		execvp(argv[0], (char *const *)argv);
		_exit(127);
	}
	int status;
	if (waitpid(pid, &status, 0) < 0) return -1;
	if (WIFEXITED(status)) return WEXITSTATUS(status);
	return -1;
}

/* Run helper, capture its stdout (one short line) into out_buf, and
 * return the exit code. out_buf is NUL-terminated; truncates silently
 * if the helper writes more than out_sz-1 bytes. */
static int run_helper_capture(const char *const argv[],
                               char *out_buf, size_t out_sz) {
	if (out_buf && out_sz > 0) out_buf[0] = '\0';
	int pipefd[2];
	if (pipe(pipefd) < 0) return -1;
	pid_t pid = fork();
	if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
	if (pid == 0) {
		close(pipefd[0]);
		dup2(pipefd[1], STDOUT_FILENO);
		close(pipefd[1]);
		execvp(argv[0], (char *const *)argv);
		_exit(127);
	}
	close(pipefd[1]);
	if (out_buf && out_sz > 1) {
		size_t total = 0;
		while (total < out_sz - 1) {
			ssize_t r = read(pipefd[0], out_buf + total,
			                 out_sz - 1 - total);
			if (r <= 0) break;
			total += r;
		}
		out_buf[total] = '\0';
		/* drop trailing newline */
		while (total > 0 && (out_buf[total - 1] == '\n' ||
		                     out_buf[total - 1] == '\r' ||
		                     out_buf[total - 1] == ' ')) {
			out_buf[--total] = '\0';
		}
	}
	close(pipefd[0]);
	int status;
	if (waitpid(pid, &status, 0) < 0) return -1;
	if (WIFEXITED(status)) return WEXITSTATUS(status);
	return -1;
}

int inject_apply(const char *strategy_str, const char *profile_key,
                 const char *domain) {
	if (!strategy_str || !profile_key || !domain) return -1;

	/* Pass strategy_str via env var to avoid shell-quoting hell — the
	 * string contains colons and equals signs, but no shell metas.
	 *
	 * The helper writes dynparams AND pins state.tsv to the correct
	 * dynamic slot (read from /opt/zapret2/dynamic-slots.conf). We do
	 * NOT call state_pin here — that would clobber the helper's pin
	 * with a sentinel-0, which routes traffic to slot=0 instead of
	 * the dynamic handler slot. */
	if (setenv("Z2K_STRATEGY", strategy_str, 1) != 0) return -1;

	const char *const argv[] = {
		HELPER_PATH, "apply", profile_key, domain, NULL
	};
	int rc = run_helper(argv);
	unsetenv("Z2K_STRATEGY");

	return rc == 0 ? 0 : -1;
}

int inject_revert(const char *profile_key, const char *domain) {
	if (!profile_key || !domain) return -1;

	/* Helper handles dynparams clear + conditional state unpin
	 * (only unpins if domain isn't in the persistent DB). */
	const char *const argv[] = {
		HELPER_PATH, "revert", profile_key, domain, NULL
	};
	return run_helper(argv) == 0 ? 0 : -1;
}

int inject_persist_winner(const char *strategy_str, const char *profile_key,
                          const char *domain) {
	if (!strategy_str || !profile_key || !domain) return -1;

	if (setenv("Z2K_STRATEGY", strategy_str, 1) != 0) return -1;

	const char *const argv[] = {
		HELPER_PATH, "persist", profile_key, domain, NULL
	};
	/* Helper writes the assigned strategy_id to stdout and exits 0
	 * on success. The exit-code path used to carry the id directly,
	 * which capped reportable ids at 254. Capture stdout instead so
	 * any DB id round-trips correctly. */
	char id_buf[32];
	int rc = run_helper_capture(argv, id_buf, sizeof(id_buf));
	unsetenv("Z2K_STRATEGY");

	if (rc < 0) return -1;
	if (rc != 0) return -1;
	if (id_buf[0] == '\0') {
		/* Empty stdout — older helper version using exit-code path.
		 * Fall back to running once more reading the exit code. */
		const char *const argv2[] = {
			HELPER_PATH, "persist", profile_key, domain, NULL
		};
		setenv("Z2K_STRATEGY", strategy_str, 1);
		int rc2 = run_helper(argv2);
		unsetenv("Z2K_STRATEGY");
		return rc2 < 0 ? -1 : rc2;
	}
	return atoi(id_buf);
}
