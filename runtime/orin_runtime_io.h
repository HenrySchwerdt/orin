/*
 * std:io runtime (stdin/stdout primitives). Header-only (static functions) so no extra object file
 * has to be linked; included by code emitted by both backends (compiler/cemit, compiler/codegen).
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline OrinObj *orin_io_some_str(const char *buf, size_t len) {
    OrinObj *s = orin_str_new(buf, (uint64_t)len);
    return orin_variant1(0, 1, ORIN_SLOT(s));
}

static inline OrinObj *orin_io_read_bytes(uint64_t n) {
    if (n == 0) return orin_io_some_str("", 0);
    char *buf = (char *)malloc(n);
    if (!buf) orin_trap("out of memory");
    size_t got = 0;
    while (got < n) {
        size_t k = fread(buf + got, 1, (size_t)(n - got), stdin);
        if (k == 0) break;
        got += k;
    }
    if (got < n) {
        free(buf);
        return orin_none();
    }
    OrinObj *r = orin_io_some_str(buf, got);
    free(buf);
    return r;
}

static inline OrinObj *orin_io_read_line(void) {
    size_t cap = 128, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) orin_trap("out of memory");
    int c, any = 0;
    while ((c = getc(stdin)) != EOF) {
        any = 1;
        if (c == '\n') break;
        if (len == cap) {
            cap *= 2;
            buf = (char *)realloc(buf, cap);
            if (!buf) orin_trap("out of memory");
        }
        buf[len++] = (char)c;
    }
    if (!any) {
        free(buf);
        return orin_none();
    }
    if (len > 0 && buf[len - 1] == '\r') len--;
    OrinObj *r = orin_io_some_str(buf, len);
    free(buf);
    return r;
}

static inline void orin_io_write_stdout(OrinObj *s) {
    fwrite(orin_str_data(s), 1, (size_t)orin_str_len(s), stdout);
    fflush(stdout);
}

#endif
