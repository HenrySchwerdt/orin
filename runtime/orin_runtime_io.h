/*
 * std:io runtime (stdin/stdout primitives). Header-only (static functions) so no extra object file
 * has to be linked; included by code emitted by the C and LLVM backends (compiler/cemit, compiler/llvm).
 *
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

static inline OrinObj *orin_io_read_bytes(uint64_t n) {
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

static inline OrinObj *orin_io_read_line(void) {
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

static inline void orin_io_write_stdout(OrinObj *s) {
    orin_platform_write(ORIN_PLATFORM_STDOUT, orin_str_data(s), (size_t)orin_str_len(s));
    orin_platform_flush();
}

/* Wall-clock time in milliseconds since the Unix epoch (std:time `nowMillis`). */
static inline int64_t orin_time_now_millis(void) {
    return orin_platform_now_millis();
}

/* Runs `cmd` through /bin/sh (system(3)); returns the exit status (-1 if it could not start or
 * was killed by a signal). Used by `orin mcp` (test/build) behind --allow-exec. */
static inline int64_t orin_io_shell(OrinObj *cmd) {
    return orin_platform_shell(orin_str_data(cmd), (size_t)orin_str_len(cmd));
}

#endif
