/* Minimal freestanding libc surface for the Orbit L0 (ADR-0055): what runtime/platform/orin_platform.h needs. Implemented in
 * ../orin_libc_orbit.c. Not a general C library. */
#ifndef ORIN_ORBIT_STDLIB_H
#define ORIN_ORBIT_STDLIB_H
#include <stddef.h>
void *malloc(size_t n);
void *realloc(void *p, size_t n);
void *calloc(size_t n, size_t m);
void free(void *p);
_Noreturn void abort(void);
#endif
