/* ADR-0045 process fixture, driven with an outer deadline by tools/test_execution.py. */
#include "../orin_platform.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>

static void tick(int sig) { (void)sig; }

int main(int argc, char **argv) {
    assert(argc == 3);
    orin_platform_init(argc, argv);
    if (getenv("ORIN_TEST_INTERRUPTS")) {
        struct sigaction act = {0};
        act.sa_handler = tick;
        sigemptyset(&act.sa_mask);
        assert(sigaction(SIGALRM, &act, NULL) == 0);
        struct itimerval timer = {{0, 10000}, {0, 10000}};
        assert(setitimer(ITIMER_REAL, &timer, NULL) == 0);
    }
    if (getenv("ORIN_TEST_IGNORE_CHLD")) assert(signal(SIGCHLD, SIG_IGN) != SIG_ERR);
    int64_t result = orin_platform_shell_timeout(argv[1], strlen(argv[1]), strtoll(argv[2], NULL, 10));
    int status;
    errno = 0;
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    printf("\nstatus=%lld\n", (long long)result);
    return 0;
}
