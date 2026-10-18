#!/bin/sh
# Spec 19 / ADR-0013 (R2): the runtime must reach the OS and libc ONLY through runtime/platform/orin_platform.h.
# Fails when a runtime source (runtime/core/*.c, runtime/core/*.h) calls a libc function directly or includes a
# libc header other than the freestanding ones. Comments and string literals are ignored.
#   tools/check_platform_boundary.sh [file ...]     (default: runtime/core/*.c runtime/core/*.h, and the `plat` declaration lint)
#
# The default run also lints the L0 declarations behind the core operation `plat` (ADR-0052 Addendum B section 6, risk 2): Orin code gets
# its ordering from L0 calls being opaque barriers (mutexes, condition variables, thread start and join), so none of the 20 functions of
# the `plat` table may be declared `static inline`, `const`, `pure`, `readnone`, `readonly`, `argmemonly` or `memory(..)` in
# runtime/platform/orin_platform.h or in the LLVM declarations (compiler/backends/llvm/runtime.or), and `nounwind` is out as well for the
# LLVM declarations (thread_exit unwinds through generated frames, risk 3). The table is read from compiler/hir/coreops.or.
set -eu
cd "$(dirname "$0")/.."
LINT=0
[ $# -gt 0 ] || { LINT=1; set -- runtime/core/*.c runtime/core/*.h; }
export LINT
exec python3 - "$@" <<'PY'
import os, re, sys

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

def plat_lint():
    """The L0 declarations behind `plat`: no attribute that would let a compiler move memory accesses across the call."""
    n = 0
    src = open("compiler/hir/coreops.or", encoding="utf-8").read()
    m = re.search(r"function platNames\(\): string\[\] \{\s*return \[(.*?)\];", src, re.S)
    names = re.findall(r'"([a-z_]+)"', m.group(1)) if m else []
    if len(names) != 20:
        print("compiler/hir/coreops.or: the plat table has %d names, expected 20" % len(names))
        return 1
    header = strip(open("runtime/platform/orin_platform.h", encoding="utf-8").read())
    bad_attr = re.compile(r"\b(static\s+inline|inline|const|pure|readnone|readonly|argmemonly)\b|__attribute__\s*\(\(\s*(const|pure)\b")
    for nm in names:
        sym = "orin_platform_" + nm
        decls = [d for d in re.split(r";|\}", header) if re.search(r"\b" + sym + r"\s*\(", d)]
        if not decls:
            print("runtime/platform/orin_platform.h: no declaration of %s" % sym)
            n += 1
        for d in decls:
            head = d[: re.search(r"\b" + sym + r"\s*\(", d).start()]
            head = head.split("\n")[-1] if "#" not in head.split("\n")[-1] else ""
            attrs = d[d.index(sym) + len(sym):]
            # the declaration up to its parameter list: the return type must not be qualified (`const char *` of getenv is a pointer to const)
            ret = re.sub(r"\bconst\s+char\s*\*", "char *", head)
            if bad_attr.search(ret) or re.search(r"__attribute__\s*\(\(\s*(const|pure)\b", attrs):
                print("runtime/platform/orin_platform.h: %s is declared with an attribute that makes the call movable: %s" % (sym, " ".join((head + sym).split())))
                n += 1
    ll = open("compiler/backends/llvm/runtime.or", encoding="utf-8").read()
    for line in ll.split("\n"):
        if "@orin_platform_" in line and re.search(r"\b(readnone|readonly|argmemonly|nounwind|memory\()", line) and "wake_" not in line:
            print("compiler/backends/llvm/runtime.or: a platform declaration with a memory or unwind attribute: %s" % line.strip())
            n += 1
    k = ll.find("function platDeclare")
    body = ll[k : ll.find("\n}\n", k)] if k >= 0 else ""
    if not body:
        print("compiler/backends/llvm/runtime.or: platDeclare not found")
        n += 1
    elif re.search(r"readnone|readonly|argmemonly|nounwind|memory\(", re.sub(r"//[^\n]*", "", body)):
        print("compiler/backends/llvm/runtime.or: platDeclare adds a memory or unwind attribute")
        n += 1
    return n


if os.environ.get("LINT") == "1":
    bad += plat_lint()
if bad:
    print("platform boundary violated: %d problem(s)" % bad)
    sys.exit(1)
print("platform boundary ok (%d files)" % len(sys.argv[1:]))
PY
