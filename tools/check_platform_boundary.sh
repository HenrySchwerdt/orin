#!/bin/sh
# Spec 19 / ADR-0013 (R2): the runtime must reach the OS and libc ONLY through runtime/platform/orin_platform.h.
# Fails when a runtime source (runtime/core/*.c, runtime/core/*.h) calls a libc function directly or includes a
# libc header other than the freestanding ones. Comments and string literals are ignored.
#   tools/check_platform_boundary.sh [file ...]     (default: runtime/core/*.c runtime/core/*.h)
set -eu
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- runtime/core/*.c runtime/core/*.h
exec python3 - "$@" <<'PY'
import re, sys

FORBIDDEN = """
fopen fclose fread fwrite fwrite_unlocked fputc fputs putc putc_unlocked putchar puts getc getchar
fgets fgetc fflush fprintf printf vprintf vfprintf snprintf sprintf vsnprintf sscanf fscanf scanf setvbuf
fseek ftell rewind ferror feof perror remove rename tmpfile
malloc calloc realloc free aligned_alloc posix_memalign mmap munmap brk sbrk
memcpy memmove memcmp memset memchr memmem strlen strcmp strncmp strcpy strncpy strcat strchr strrchr
strstr strerror strtol strtoul strtoll strtoull atoi atol getenv setenv putenv
exit _exit abort atexit quick_exit system popen pclose fork execv execvp execl execlp waitpid wait
open close read write lseek stat fstat lstat access unlink mkdir opendir readdir
time clock gettimeofday clock_gettime nanosleep sleep usleep rand srand signal raise sigaction
pthread_create pthread_mutex_lock
""".split()
ALLOWED_INCLUDES = {"stddef.h", "stdint.h", "stdbool.h", "limits.h", "stdarg.h"}


def strip(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * src.count("\n", i, j))
            i = j
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(c + c)
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


call = re.compile(r"(?<![\w.>])(" + "|".join(FORBIDDEN) + r")\s*\(")
inc = re.compile(r'^\s*#\s*include\s*<([^>]+)>', re.M)
bad = 0
for path in sys.argv[1:]:
    raw = open(path, encoding="utf-8").read()
    # includes are checked on the comment-stripped text but BEFORE string stripping matters not
    text = strip(raw)
    for m in re.finditer(r'^\s*#\s*include\s*<([^>]+)>', raw, re.M):
        if m.group(1) not in ALLOWED_INCLUDES:
            line = raw.count("\n", 0, m.start()) + 1
            print("%s:%d: forbidden include <%s> (use runtime/platform/orin_platform.h)" % (path, line, m.group(1)))
            bad += 1
    for m in call.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        print("%s:%d: direct libc call %s() (use orin_platform_*)" % (path, line, m.group(1)))
        bad += 1
if bad:
    print("platform boundary violated: %d problem(s)" % bad)
    sys.exit(1)
print("platform boundary ok (%d files)" % len(sys.argv[1:]))
PY
