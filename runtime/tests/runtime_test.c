/* Runtime-only tests. Build: cc -I runtime runtime/tests/runtime_test.c runtime/orin_runtime.c platform/orin_platform.c
 * Optionally with -fsanitize=address,undefined. Exits 0 and prints "ok" on success. */
#include "orin_runtime.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(c)                                                                                \
    do {                                                                                        \
        if (!(c)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                        \
            failures++;                                                                         \
        }                                                                                       \
    } while (0)

static OrinObj *S(const char *s) { return orin_str_new(s, strlen(s)); }
static int streq(OrinObj *o, const char *s) {
    return orin_str_len(o) == strlen(s) && memcmp(orin_str_data(o), s, strlen(s)) == 0;
}

ORIN_STRING_LIT(lit_nul, 3, "a\000b");

static void test_strings(void) {
    int64_t base = orin_live_count();
    OrinObj *a = S("hello"), *b = S(" world");
    OrinObj *c = orin_str_concat(a, b);
    CHECK(streq(c, "hello world"));
    CHECK(orin_str_eq(c, c));
    OrinObj *sub = orin_str_substring(c, 6, 11);
    CHECK(streq(sub, "world"));
    OrinObj *idx = orin_str_index_of(c, sub);
    CHECK(orin_tag(idx) == 0 && orin_struct_get(idx, 0) == 6);
    OrinObj *miss = S("zzz");
    OrinObj *idx2 = orin_str_index_of(c, miss);
    CHECK(orin_tag(idx2) == 1);
    CHECK(orin_str_includes(c, sub) && orin_str_starts_with(c, a) && orin_str_ends_with(c, sub));
    OrinObj *comma = S(",");
    OrinObj *csv = S("a,b,,c");
    OrinObj *parts = orin_str_split(csv, comma);
    CHECK(orin_array_len(parts) == 4);
    OrinObj *joined = orin_array_join(parts, comma);
    CHECK(streq(joined, "a,b,,c"));
    OrinObj *trimmed = S("  \t x y\n ");
    OrinObj *tr = orin_str_trim(trimmed);
    CHECK(streq(tr, "x y"));
    CHECK(orin_str_len(lit_nul) == 3 && orin_str_data(lit_nul)[1] == 0 && orin_str_data(lit_nul)[2] == 'b');
    OrinObj *n = S("-42");
    OrinObj *p = orin_parse_int(n);
    CHECK(orin_tag(p) == 0 && (int64_t)orin_struct_get(p, 0) == -42);
    OrinObj *bad = S("12x");
    OrinObj *p2 = orin_parse_int(bad);
    CHECK(orin_tag(p2) == 1);
    OrinObj *big = S("9223372036854775808");
    OrinObj *p3 = orin_parse_int(big);
    CHECK(orin_tag(p3) == 1);
    OrinObj *mn = S("-9223372036854775808");
    OrinObj *p4 = orin_parse_int(mn);
    CHECK(orin_tag(p4) == 0 && (int64_t)orin_struct_get(p4, 0) == INT64_MIN);
    OrinObj *its = orin_int_to_string(INT64_MIN);
    CHECK(streq(its, "-9223372036854775808"));
    /* append: in place when unique */
    OrinObj *acc = S("x");
    for (int i = 0; i < 1000; i++) acc = orin_str_append(acc, comma);
    CHECK(orin_str_len(acc) == 1001);
    OrinObj *shared = orin_dup(acc);
    OrinObj *acc2 = orin_str_append(acc, comma); /* consumes one count of acc; shared keeps old */
    CHECK(orin_str_len(shared) == 1001 && orin_str_len(acc2) == 1002);
    OrinObj *os[] = {a, b, c, sub, idx, miss, idx2, comma, csv, parts, joined, trimmed, tr, n, p, bad, p2,
                     big, p3, mn, p4, its, shared, acc2};
    for (size_t i = 0; i < sizeof os / sizeof *os; i++) orin_release(os[i]);
    CHECK(orin_live_count() == base);
}

static void test_arrays_cow(void) {
    int64_t base = orin_live_count();
    OrinObj *xs = orin_array_new(0, 1);
    for (int i = 0; i < 100; i++) orin_array_push(xs, ORIN_SLOT(orin_int_to_string(i)));
    CHECK(orin_array_len(xs) == 100);
    OrinObj *ys = orin_dup(xs);
    xs = orin_make_unique(xs); /* shared -> copy */
    CHECK(xs != ys && ys->rc == 1 && xs->rc == 1);
    OrinObj *last = orin_array_pop(xs);
    CHECK(orin_tag(last) == 0 && streq(ORIN_REF(orin_struct_get(last, 0)), "99"));
    CHECK(orin_array_len(xs) == 99 && orin_array_len(ys) == 100);
    OrinObj *sl = orin_array_slice(ys, 10, 20);
    CHECK(orin_array_len(sl) == 10 && streq(ORIN_REF(orin_array_at(sl, 0)), "10"));
    OrinObj *cc = orin_array_concat(sl, sl);
    CHECK(orin_array_len(cc) == 20);
    OrinObj *g = orin_array_get(cc, 19), *g2 = orin_array_get(cc, 20);
    CHECK(orin_tag(g) == 0 && orin_tag(g2) == 1);
    /* nested: record holding an array; unique-path update leaves the shared copy untouched */
    OrinObj *rec = orin_struct_new(0, 2, 2);
    orin_struct_set(rec, 0, 7);
    orin_struct_set(rec, 1, ORIN_SLOT(orin_dup(xs)));
    OrinObj *rec2 = orin_dup(rec);
    rec = orin_make_unique(rec);
    uint64_t *slot = orin_struct_slot_ptr(rec, 1);
    OrinObj *inner = orin_make_unique(ORIN_REF(*slot));
    *slot = ORIN_SLOT(inner);
    uint64_t *el = orin_array_slot_ptr(inner, 0);
    OrinObj *old = ORIN_REF(*el);
    *el = ORIN_SLOT(S("changed"));
    orin_release(old);
    CHECK(streq(ORIN_REF(orin_array_at(ORIN_REF(orin_struct_get(rec2, 1)), 0)), "0"));
    CHECK(streq(ORIN_REF(orin_array_at(ORIN_REF(orin_struct_get(rec, 1)), 0)), "changed"));
    OrinObj *all[] = {xs, ys, last, sl, cc, g, g2, rec, rec2};
    for (size_t i = 0; i < sizeof all / sizeof *all; i++) orin_release(all[i]);
    CHECK(orin_live_count() == base);
}

static void test_deep_chain(void) {
    int64_t base = orin_live_count();
    OrinObj *list = orin_nullary(1);
    for (int i = 0; i < 1000000; i++) {
        OrinObj *n = orin_struct_new(0, 2, 2);
        orin_struct_set(n, 0, (uint64_t)i);
        orin_struct_set(n, 1, ORIN_SLOT(list));
        list = n;
    }
    orin_release(list); /* must not overflow the stack */
    CHECK(orin_live_count() == base);
}

static void test_misc(void) {
    CHECK(orin_add_i(1, 2) == 3 && orin_div_i(-7, 2) == -3 && orin_rem_i(-7, 2) == -1);
    CHECK(orin_int_to_usize(5) == 5 && orin_usize_to_int(5) == 5);
    OrinObj *none = orin_none();
    CHECK(none->rc < 0 && orin_nullary(1) == none);
    orin_release(none); /* no-op on immortal */
    orin_release(NULL);
    OrinObj *r = orin_variant1(1, 1, ORIN_SLOT(S("err")));
    CHECK(orin_tag(r) == 1 && streq(ORIN_REF(orin_res_unwrap_err(r)), "err"));
    orin_release(r);
    OrinObj *p = S("/definitely/not/here");
    OrinObj *rd = orin_fs_read_file(p);
    CHECK(orin_tag(rd) == 1 && !orin_fs_exists(p));
    orin_release(rd);
    orin_release(p);
}

int main(int argc, char **argv) {
    orin_init(argc, argv);
    test_strings();
    test_arrays_cow();
    test_deep_chain();
    test_misc();
    if (failures) return 1;
    printf("ok\n");
    orin_flush();
    return 0;
}
