/*
 * Out-of-line symbols for the LLVM IR backend (compiler/llvm, ADR-0006).
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
_Static_assert(offsetof(OrinStruct, slots) == 32, "OrinStruct.slots");

OrinObj *orinl_io_read_bytes(uint64_t n) { return orin_io_read_bytes(n); }
OrinObj *orinl_io_read_line(void) { return orin_io_read_line(); }
void orinl_io_write_stdout(OrinObj *s) { orin_io_write_stdout(s); }
int64_t orinl_io_shell(OrinObj *cmd) { return orin_io_shell(cmd); }
int64_t orinl_str_char_code_at(OrinObj *s, uint64_t i) { return orin_str_char_code_at(s, i); }
