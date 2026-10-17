/* Minimal freestanding libc surface for the Orbit L0 (ADR-0055). Implemented in ../orin_libc_orbit.c. */
#ifndef ORIN_ORBIT_STRING_H
#define ORIN_ORBIT_STRING_H
#include <stddef.h>
void *memcpy(void *restrict d, const void *restrict s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *p, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
#endif
