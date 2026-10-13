/* Tiny helper for tools/bench.py: runs a command and writes its peak RSS (KiB, ru_maxrss of the
 * child) to a file. Needed because Python's own fork inflates ru_maxrss with the interpreter's
 * RSS, and /usr/bin/time may not be installed.
 * Usage: rss_probe <outfile> cmd [args...]   (exit status = child's status) */
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    pid_t p = vfork();
    if (p == 0) {
        execvp(argv[2], argv + 2);
        _exit(127);
    }
    int st;
    struct rusage ru;
    if (wait4(p, &st, 0, &ru) < 0) return 2;
    FILE *f = fopen(argv[1], "w");
    if (f) {
        fprintf(f, "%ld\n", ru.ru_maxrss);
        fclose(f);
    }
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
