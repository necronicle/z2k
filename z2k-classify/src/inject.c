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
#include "state.h"

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

int inject_apply(const char *strategy_str, const char *profile_key,
                 const char *domain) {
	if (!strategy_str || !profile_key || !domain) return -1;

	/* Pass strategy_str via env var to avoid shell-quoting hell — the
	 * string contains colons and equals signs, but no shell metas. */
	if (setenv("Z2K_STRATEGY", strategy_str, 1) != 0) return -1;

	const char *const argv[] = {
		HELPER_PATH, "apply", profile_key, domain, NULL
	};
	int rc = run_helper(argv);
	unsetenv("Z2K_STRATEGY");

	if (rc != 0) return -1;

	/* Pin our domain to the dynamic strategy slot so probe hits it. */
	const char *path = state_path_pick();
	return state_pin(path, profile_key, domain, INJECT_DYNAMIC_STRATEGY_ID);
}

int inject_revert(const char *profile_key, const char *domain) {
	if (!profile_key || !domain) return -1;

	/* Unpin first so probe traffic resumes normal rotation if user
	 * re-runs anything during the regen window. */
	const char *path = state_path_pick();
	state_unpin(path, profile_key, domain);

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
	int rc = run_helper(argv);
	unsetenv("Z2K_STRATEGY");

	if (rc < 0) return -1;
	/* Helper exits with the assigned strategy_id (e.g. 48 for rkn_tcp
	 * if 47 was the previous max). Cap at 254 to fit exit code. */
	return rc;
}
