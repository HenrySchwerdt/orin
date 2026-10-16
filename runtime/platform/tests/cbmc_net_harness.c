/* CBMC harnesses for the network primitives of the L0 platform layer (ADR-0033): buffer bounds of recv / send and the
 * scope checks. Run by tools/verify_platform.sh:
 *   cbmc runtime/platform/tests/cbmc_net_harness.c --function <harness> --bounds-check --pointer-check --unwind N ...
 * The harness INCLUDES orin_platform.c (to reach the static scope functions) and replaces the system calls by stubs
 * that count calls and check their arguments: `recv` / `send` assert that the buffer they are given is valid for exactly
 * the length they are asked to transfer, and return an arbitrary value (including more than was asked); `socket`, `bind`,
 * ... only count. Contents, lengths and ranges are nondeterministic within small bounds (bounded model checking, not a
 * proof for all sizes). */
#include "../orin_platform.c"

#include <assert.h>

static int g_calls;      /* system calls that act on the network (everything but poll/recv/send) */
static size_t g_recv_n;  /* the length the last recv / send was asked for */

int socket(int d, int t, int p) { g_calls++; int r; return r; }
int bind(int fd, const struct sockaddr *a, socklen_t l) { g_calls++; int r; return r; }
int listen(int fd, int b) { g_calls++; int r; return r; }
int accept(int fd, struct sockaddr *a, socklen_t *l) { g_calls++; int r; return r; }
int connect(int fd, const struct sockaddr *a, socklen_t l) { g_calls++; int r; return r; }
int getaddrinfo(const char *h, const char *s, const struct addrinfo *hint, struct addrinfo **res) { g_calls++; *res = 0; return EAI_FAIL; }
int shutdown(int fd, int how) { g_calls++; int r; return r; }
int fcntl(int fd, int cmd, ...) { int r; return r; }
int setsockopt(int fd, int l, int o, const void *v, socklen_t n) { int r; return r; }
int getsockopt(int fd, int l, int o, void *v, socklen_t *n) { int r; return r; }
int poll(struct pollfd *p, nfds_t n, int t) { int r; __CPROVER_assume(r >= 0 && r <= 1); return r; } /* the EINTR retry is tested, not modelled */
ssize_t recv(int fd, void *buf, size_t n, int flags) {
    __CPROVER_assert(__CPROVER_w_ok(buf, n), "recv: the buffer is writable for the requested length");
    g_recv_n = n;
    ssize_t r;
    return r; /* may exceed n: the caller must not trust it blindly */
}
ssize_t send(int fd, const void *buf, size_t n, int flags) {
    __CPROVER_assert(__CPROVER_r_ok(buf, n), "send: the data is readable for the requested length");
    g_recv_n = n;
    ssize_t r;
    return r;
}

enum { CAP = 6 };

static orin_platform_net live(unsigned kind) {
    orin_platform_net h;
    orin_platform_mem_set(&h, 0, sizeof h);
    h.magic = ORIN_PLATFORM_NET_MAGIC, h.kind = kind, h.can = 3, h.fd = 3;
    return h;
}

/* recv never asks the OS for more than cap bytes, never reports more than cap, and *out_len == 0 unless it returns 0 */
void harness_net_recv(void) {
    char area[CAP + 2];
    size_t cap, len = 99;
    int ms;
    __CPROVER_assume(cap <= CAP);
    orin_platform_net s = live(ORIN_PLATFORM_NET_STREAM);
    int r = orin_platform_stream_recv(&s, area + 1, cap, ms, &len);
    if (r == 0) assert(len >= 1 && len <= cap);
    else assert(len == 0);
    if (g_recv_n) assert(g_recv_n == cap);
    if (cap == 0) assert(r != 0);
    if (ms < 0 || ms > ORIN_PLATFORM_NET_MAXMS) assert(r != 0 && g_recv_n == 0); /* no infinite or negative wait */
}

/* send never reads past len bytes and reports at most len */
void harness_net_send(void) {
    char data[CAP];
    size_t len, sent = 99;
    int ms;
    __CPROVER_assume(len <= CAP);
    orin_platform_net s = live(ORIN_PLATFORM_NET_STREAM);
    int r = orin_platform_stream_send(&s, data, len, ms, &sent);
    if (r == 0) assert(sent <= len);
    else assert(sent == 0);
    if (g_recv_n) assert(g_recv_n == len);
}

static void nondet_text(char *b, size_t n) { /* a small alphabet that contains every special character of a pattern */
    for (size_t i = 0; i < n; i++) {
        char c;
        __CPROVER_assume(c == 'a' || c == 'B' || c == '.' || c == '*');
        b[i] = c;
    }
}

/* narrowing never widens: whatever the narrowed grant covers, its parent covered; and a narrowed grant has only the
 * capability that was asked for. Host patterns of 1..4 characters, ports 0..3. */
void harness_net_narrow(void) {
    char ph[4], ch[4], h[4];
    size_t pl, cl, hl;
    int plo, phi, clo, chi, port;
    __CPROVER_assume(pl >= 1 && pl <= 4 && cl >= 1 && cl <= 4 && hl >= 1 && hl <= 4);
    __CPROVER_assume(plo >= 0 && plo <= phi && phi <= 3 && clo >= 0 && clo <= chi && chi <= 3 && port >= 0 && port <= 3);
    nondet_text(ph, pl), nondet_text(ch, cl), nondet_text(h, hl);
    unsigned what;
    __CPROVER_assume(what == ORIN_PLATFORM_NET_LISTEN || what == ORIN_PLATFORM_NET_CONNECT);
    orin_platform_net parent = live(ORIN_PLATFORM_NET_GRANT), child;
    parent.sc[what - 1].hl = pl, parent.sc[what - 1].lo = (unsigned)plo, parent.sc[what - 1].hi = (unsigned)phi;
    orin_platform_mem_copy(parent.sc[what - 1].h, ph, pl);
    int e = orin_platform_net_narrow(&parent, what, ch, cl, clo, chi, &child);
    if (e == 0 && child.can) {
        assert(child.can == what);
        if (net_scope(&child, what, h, hl, port)) assert(net_scope(&parent, what, h, hl, port));
    }
    /* a parent without the capability yields a grant that can do nothing */
    parent.can = 3 & ~what;
    e = orin_platform_net_narrow(&parent, what, ch, cl, clo, chi, &child);
    assert(e != 0 || child.can == 0);
}

/* a request outside the scope, or on a handle that is not a live grant of the right kind, or under ORIN_DENY=net, is refused
 * with EPERM BEFORE any system call */
void harness_net_refuse(void) {
    char host[4], name[4], out[8];
    size_t hl, nl, ol;
    int port, ms, opt;
    __CPROVER_assume(hl >= 1 && hl <= 4 && nl >= 1 && nl <= 4);
    nondet_text(host, hl), nondet_text(name, nl);
    orin_platform_net g = live(ORIN_PLATFORM_NET_GRANT), o;
    g.sc[0].hl = 1, g.sc[0].h[0] = 'a', g.sc[0].lo = 1, g.sc[0].hi = 2; /* listen: "a", ports 1..2 */
    g.sc[1].hl = 3, g.sc[1].h[0] = '*', g.sc[1].h[1] = '.', g.sc[1].h[2] = 'a', g.sc[1].lo = 1, g.sc[1].hi = 2;
    unsigned mode;
    __CPROVER_assume(mode <= 2);
    if (mode == 1) g.deny = 1;         /* ORIN_DENY=net */
    if (mode == 2) g.kind = ORIN_PLATFORM_NET_STREAM; /* the wrong kind of handle */
    int outside = mode != 0 || !(hl == 1 && host[0] == 'a' && port >= 1 && port <= 2);
    int outp = 0;
    int e1 = orin_platform_tcp_listen(&g, host, hl, port, 8, opt, &o, &outp);
    if (outside) assert(e1 == ORIN_PLATFORM_EPERM && g_calls == 0);
    g_calls = 0;
    int star = 0;
    for (size_t i = 0; i < hl; i++) star |= host[i] == '*';
    int covered = !star && hl >= 3 && host[hl - 2] == '.' && host[hl - 1] == 'a' && port >= 1 && port <= 2;
    int e2 = orin_platform_tcp_connect(&g, host, hl, port, ms, opt, &o);
    if (mode != 0 || !covered) assert(e2 == ORIN_PLATFORM_EPERM && g_calls == 0);
    int e3 = orin_platform_dns_resolve(&g, name, nl, out, sizeof out, &ol);
    if (mode != 0) assert(e3 == ORIN_PLATFORM_EPERM && g_calls == 0 && ol == 0);
}
