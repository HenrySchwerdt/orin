/*
 * Runtime helpers used only by code emitted from MIR (compiler/cemit). Header-only (static
 * inline) so no extra object file has to be linked. Operations that the MIR verifier guarantees
 * apply to a Unique object (docs/mir.md): take / put / in-place replace of a slot.
 */
#ifndef ORIN_RUNTIME_MIR_H
#define ORIN_RUNTIME_MIR_H

#include "orin_runtime.h"

/* Unboxed aggregates (docs/mir.md v2.2, ADR-0038 step 1): an Option / Result / record / pair of scalars held by value in
   n + 1 words (w[0] the tag, w[1..n] the payload), passed and returned by value; no heap object, no reference count. */
typedef struct { uint64_t w[1]; } OrinV0;
typedef struct { uint64_t w[2]; } OrinV1;
typedef struct { uint64_t w[3]; } OrinV2;
typedef struct { uint64_t w[4]; } OrinV3;

/* Take the slot's value out (the slot becomes empty/NULL until put back). Object must be unique. */
static inline uint64_t orin_mir_struct_take(OrinObj *o, uint32_t i) {
    uint64_t *p = orin_struct_slot_ptr(o, i);
    uint64_t v = *p;
    *p = 0;
    return v;
}

/* Overwrite slot i (object must be unique), releasing the old value if the slot is a reference. */
static inline void orin_mir_struct_replace(OrinObj *o, uint32_t i, uint64_t slot) {
    orin_chk_slot(o, i);
    OrinStruct *s = (OrinStruct *)o;
    uint64_t old = s->slots[i];
    s->slots[i] = slot;
    if ((s->refmask >> i) & 1) orin_release(ORIN_REF(old));
}

static inline uint64_t orin_mir_array_take(OrinObj *a, uint64_t i) {
    uint64_t *p = orin_array_slot_ptr(a, i); /* traps if out of range */
    uint64_t v = *p;
    *p = 0;
    return v;
}

static inline void orin_mir_array_put(OrinObj *a, uint64_t i, uint64_t slot) {
    *orin_array_slot_ptr(a, i) = slot;
}

static inline void orin_mir_array_replace(OrinObj *a, uint64_t i, uint64_t slot) {
    uint64_t *p = orin_array_slot_ptr(a, i);
    uint64_t old = *p;
    *p = slot;
    if (((OrinArray *)a)->is_ref) orin_release(ORIN_REF(old));
}

/* push onto a possibly shared array: copy-on-write, returns the (owned) array to store back. */
static inline OrinObj *orin_mir_array_push(OrinObj *a, uint64_t slot) {
    a = orin_make_unique(a);
    orin_array_push(a, slot);
    return a;
}

#endif
