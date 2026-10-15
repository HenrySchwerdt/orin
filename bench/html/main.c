// HTML rendering: a 2000-row product table rendered 400 times into one growing buffer (memcpy, escape loop).
// Hand-written baseline; bench/html_hand/main.or and bench/html/main.go print the same bytes.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ROWS 2000
#define PAGES 400

typedef struct { char *p; size_t len, cap; } Buf;

static void reserve(Buf *b, size_t n) {
  if (b->len + n > b->cap) {
    size_t c = b->cap ? b->cap : 64;
    while (c < b->len + n) c *= 2;
    b->p = realloc(b->p, c);
    b->cap = c;
  }
}
static void put(Buf *b, const char *s, size_t n) { reserve(b, n); memcpy(b->p + b->len, s, n); b->len += n; }
#define LIT(b, s) put(b, s, sizeof(s) - 1)
static void putint(Buf *b, long v) { char t[32]; int n = snprintf(t, sizeof t, "%ld", v); put(b, t, (size_t)n); }

static void escape(Buf *b, const char *s) {
  size_t start = 0, i = 0;
  for (; s[i]; i++) {
    const char *r = 0; size_t n = 0;
    switch (s[i]) {
      case '&': r = "&amp;"; n = 5; break;
      case '<': r = "&lt;"; n = 4; break;
      case '>': r = "&gt;"; n = 4; break;
      case '"': r = "&quot;"; n = 6; break;
      case '\'': r = "&#39;"; n = 5; break;
    }
    if (r) { put(b, s + start, i - start); put(b, r, n); start = i + 1; }
  }
  put(b, s + start, i - start);
}

static int lower_eq(const char *s, size_t n, const char *w) {
  if (strlen(w) != n) return 0;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (c >= 'A' && c <= 'Z') c += 32;
    if (c != w[i]) return 0;
  }
  return 1;
}

static const char *safe_url(const char *u) {
  for (size_t i = 0; u[i]; i++) {
    char c = u[i];
    if (c == '/' || c == '?' || c == '#') return u;
    if (c == ':') {
      if (lower_eq(u, i, "http") || lower_eq(u, i, "https") || lower_eq(u, i, "mailto") || lower_eq(u, i, "tel")) return u;
      return "about:invalid#orin-unsafe-url";
    }
  }
  return u;
}

static char *names[ROWS], *urls[ROWS];
static long prices[ROWS];

static void render(Buf *b) {
  b->len = 0;
  LIT(b, "<html><head><title>Products</title></head><body><h1 class=\"title\">Catalog &amp; Prices</h1><table class=\"products\">");
  for (int i = 0; i < ROWS; i++) {
    LIT(b, "<tr data-id=\""); putint(b, i);
    if (i % 2 == 0) LIT(b, "\" class=\"row even\">"); else LIT(b, "\" class=\"row odd\">");
    LIT(b, "<td class=\"name\">"); escape(b, names[i]);
    LIT(b, "</td><td class=\"price\">"); putint(b, prices[i]);
    LIT(b, "</td><td><a href=\""); escape(b, safe_url(urls[i]));
    LIT(b, "\">details</a></td><td><input type=\"checkbox\"");
    if (i % 3 == 0) LIT(b, " disabled");
    LIT(b, "></td></tr>");
  }
  LIT(b, "</table><p>"); putint(b, ROWS); LIT(b, " items</p></body></html>");
}

int main(void) {
  for (int i = 0; i < ROWS; i++) {
    char t[128];
    snprintf(t, sizeof t, "Item %d%s", i, i % 7 == 0 ? " <b>&\"sale\"</b> it's" : "");
    names[i] = strdup(t);
    if (i % 11 == 0) snprintf(t, sizeof t, "javascript:alert(%d)", i); else snprintf(t, sizeof t, "/item/%d", i);
    urls[i] = strdup(t);
    prices[i] = ((long)i * 37) % 1000;
  }
  Buf b = {0, 0, 0};
  long total = 0;
  for (int p = 0; p < PAGES; p++) { render(&b); total += (long)b.len; }
  long h = 0;
  for (size_t i = 0; i < b.len; i++) h = (h * 31 + (unsigned char)b.p[i]) % 1000000007L;
  printf("bytes %ld\nhash %ld\nhead ", total, h);
  fwrite(b.p, 1, b.len < 120 ? b.len : 120, stdout);
  printf("\n");
  return 0;
}
