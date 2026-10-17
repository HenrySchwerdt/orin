/* Minimal freestanding libc surface for the Orbit L0 (ADR-0055): the errno values orin_platform.h names (Linux numbering). */
#ifndef ORIN_ORBIT_ERRNO_H
#define ORIN_ORBIT_ERRNO_H
#define EPERM 1
#define ENOENT 2
#define ENOMEM 12
#define EACCES 13
#define EBUSY 16
#define EINVAL 22
#define EDEADLK 35
#endif
