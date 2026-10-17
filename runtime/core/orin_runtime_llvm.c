/*
 * Out-of-line symbols for the LLVM IR backend (compiler/backends/llvm, ADR-0006).
 *
 * The textual IR emitted by `orin compile --backend=llvm` implements the small hot operations
 * (retain/release, field and array access, checked arithmetic) itself, against the object layout
 * asserted below, and calls the existing C runtime for everything else. The only header-inline
 * runtime functions it cannot express as IR (std:io primitives, string byte access) are exported here.
 * Nothing in this file changes runtime semantics.
 */
#include "orin_runtime.h"
#include "orin_runtime_io.h"
#include <stddef.h>

_Static_assert(offsetof(OrinObj, rc) == 0, "OrinObj.rc");
_Static_assert(offsetof(OrinObj, kind) == 8, "OrinObj.kind");
_Static_assert(offsetof(OrinObj, tag) == 12, "OrinObj.tag");
_Static_assert(offsetof(OrinString, len) == 16, "OrinString.len");
_Static_assert(offsetof(OrinString, cap) == 24, "OrinString.cap");
_Static_assert(offsetof(OrinString, data) == 32, "OrinString.data");
_Static_assert(offsetof(OrinArray, len) == 16, "OrinArray.len");
_Static_assert(offsetof(OrinArray, cap) == 24, "OrinArray.cap");
_Static_assert(offsetof(OrinArray, items) == 40, "OrinArray.items");
_Static_assert(offsetof(OrinStruct, nslots) == 16, "OrinStruct.nslots");
_Static_assert(offsetof(OrinStruct, slots) == 32, "OrinStruct.slots");
_Static_assert(ORIN_K_ARRAY == 2, "ORIN_K_ARRAY (hard-coded in @orinl_array_slot / @orinl_array_push)");
_Static_assert(ORIN_K_STRUCT == 3, "ORIN_K_STRUCT (hard-coded in @orinl_slot)");

/* The failed allocation of the core operations memAlloc / memRealloc (compiler/hir/coreops.or) in LLVM modules. */
void orin_oom(void) { orin_trap("out of memory"); }

OrinObj *orinl_io_read_bytes(int64_t g, uint64_t n) { return orin_io_read_bytes(g, n); }
OrinObj *orinl_io_read_line(int64_t g) { return orin_io_read_line(g); }
void orinl_io_write_stdout(int64_t g, OrinObj *s) { orin_io_write_stdout(g, s); }
int64_t orinl_io_shell(int64_t g, OrinObj *cmd) { return orin_io_shell(g, cmd); }
int64_t orinl_io_shell_timeout(int64_t g, OrinObj *cmd, int64_t seconds) { return orin_io_shell_timeout(g, cmd, seconds); }
int64_t orinl_time_now_millis(int64_t g) { return orin_time_now_millis(g); }
OrinObj *orinl_time_monotonic_millis(int64_t g) { return orin_time_monotonic_millis(g); }
int64_t orinl_str_char_code_at(OrinObj *s, uint64_t i) { return orin_str_char_code_at(s, i); }

/*
 * Trap entry points whose result type is the result type of the generated function that calls them (ADR-0038 §8 gate 1).
 * The IR traps with `ret (tail call @orinl_trap_<t>(msg))`: unlike `call @orin_trap` + `unreachable` this is a plain
 * tail call (a `jmp`), so the trap block needs no stack frame and LLVM can shrink-wrap the prologue of a function with
 * checked arithmetic. None of them returns.
 */
void orinl_trap_v(const char *msg) { orin_trap(msg); }
void *orinl_trap_p(const char *msg) { orin_trap(msg); }
double orinl_trap_f(const char *msg) { orin_trap(msg); }
int64_t orinl_trap_i(const char *msg) { orin_trap(msg); }
