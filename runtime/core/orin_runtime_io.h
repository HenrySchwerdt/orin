/*
 * std:io runtime (stdin/stdout primitives). Header-only (static functions) so no extra object file
 * has to be linked; included by code emitted by the C and LLVM backends (compiler/backends/c, compiler/backends/llvm).
 *
 *   (every function takes the std:io / clock / process grant first, ADR-0027)
 *   orin_io_read_bytes(n)   Option<string>: exactly n bytes from stdin, None if EOF is reached first
 *   orin_io_read_line()     Option<string>: next line without "\n" / "\r\n", None at EOF
 *   orin_io_write_stdout(s) writes s to stdout without a newline, then flushes
 *
 * Strings are byte strings; no encoding is assumed. Stdout shares the stdio buffer used by
 * console.log, so output order is preserved.
 */
#ifndef ORIN_RUNTIME_IO_H
#define ORIN_RUNTIME_IO_H

#include "orin_runtime.h"
#include "../platform/orin_platform.h"

static inline OrinObj *orin_io_some_str(const char *buf, size_t len) {
    OrinObj *s = orin_str_new(buf, (uint64_t)len);
    return orin_variant1(0, 1, ORIN_SLOT(s));
}

static inline OrinObj *orin_io_read_bytes(int64_t g, uint64_t n) {
    orin_cap_require(g, 3, "readBytes");
    if (n == 0) return orin_io_some_str("", 0);
    char *buf = (char *)orin_platform_alloc(n);
    if (!buf) orin_trap("out of memory");
    size_t got = orin_platform_stdin_read(buf, (size_t)n);
    if (got < n) {
        orin_platform_free(buf);
        return orin_none();
    }
    OrinObj *r = orin_io_some_str(buf, got);
    orin_platform_free(buf);
    return r;
}

static inline OrinObj *orin_io_read_line(int64_t g) {
    orin_cap_require(g, 3, "readLine");
    size_t cap = 128, len = 0;
    char *buf = (char *)orin_platform_alloc(cap);
    if (!buf) orin_trap("out of memory");
    int c, any = 0;
    while ((c = orin_platform_stdin_getc()) >= 0) {
        any = 1;
        if (c == '\n') break;
        if (len == cap) {
            cap *= 2;
            buf = (char *)orin_platform_realloc(buf, cap);
            if (!buf) orin_trap("out of memory");
        }
        buf[len++] = (char)c;
    }
    if (!any) {
        orin_platform_free(buf);
        return orin_none();
    }
    if (len > 0 && buf[len - 1] == '\r') len--;
    OrinObj *r = orin_io_some_str(buf, len);
    orin_platform_free(buf);
    return r;
}

static inline void orin_io_write_stdout(int64_t g, OrinObj *s) {
    orin_cap_require(g, 3, "writeStdout");
    orin_platform_write(ORIN_PLATFORM_STDOUT, orin_str_data(s), (size_t)orin_str_len(s));
    orin_platform_flush();
}

/* Wall-clock time in milliseconds since the Unix epoch (std:time `nowMillis`). */
static inline int64_t orin_time_now_millis(int64_t g) {
    orin_cap_require(g, 4, "nowMillis");
    return orin_platform_now_millis();
}

/* Option<int>: None on a failed/invalid monotonic read; grant checks precede the read. */
static inline OrinObj *orin_time_monotonic_millis(int64_t g) {
    orin_cap_require(g, 4, "monotonicMillis");
    int64_t now = orin_platform_monotonic_millis();
    return now < 0 ? orin_nullary(1) : orin_variant1(0, 0, (uint64_t)now);
}

/* Runs `cmd` through /bin/sh (system(3)); returns the exit status (-1 if it could not start or
 * was killed by a signal). Used by `orin mcp` (test/build) behind --allow-exec. */
static inline int64_t orin_io_shell(int64_t g, OrinObj *cmd) {
    orin_cap_require_spawn(g);
    return orin_platform_shell(orin_str_data(cmd), (size_t)orin_str_len(cmd));
}

/* Bounded shell; -2 timeout, -1 spawn/signal/invalid-duration/system error, 0..255 exit. */
static inline int64_t orin_io_shell_timeout(int64_t g, OrinObj *cmd, int64_t seconds) {
    orin_cap_require_spawn(g);
    return orin_platform_shell_timeout(orin_str_data(cmd), (size_t)orin_str_len(cmd), seconds);
}

#endif
