#!/usr/bin/env python3
"""The character tables of stdlib/http.or (ADR-0030 §3, std:http).

Orin has no constant arrays, so the byte classification of the HTTP/1.1 parser is a pair of 256-character string constants
read with `charCodeAt`. This script derives them from the RFC 9110 / 9112 character sets:

  HTTP_CLASS  the class code of every byte:
      0 control (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F, 0x7F)   1 LF   2 CR   3 HTAB   4 SP   5 obs-text (0x80-0xFF)
      6 other VCHAR   7 ':'   8 ';'   10 token symbol (!#$%&'*+-.^_`|~)   11 letter (non-hex)   12 hex letter   13 digit
    ordered so that "token character" is class >= 10, "may occur in a field value" is class >= 3, "request-target
    character" is class >= 6 (0x21..0x7E) and "hex digit" is class >= 12 or 13 (see HTTP_HEXV for the value);
  HTTP_HEXV   the value of a hex digit, 16 for every other byte.

Usage: python3 tools/gen_http_tables.py           print the two constant declarations
       python3 tools/gen_http_tables.py --check   fail unless stdlib/http.or contains exactly these declarations
tests/std/http_test.or recomputes the same classes from explicit RFC character lists (a second, independent check).
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def cls(c):
    if c == 10:
        return 1
    if c == 13:
        return 2
    if c == 9:
        return 3
    if c == 32:
        return 4
    if c >= 128:
        return 5
    if c < 32 or c == 127:
        return 0
    ch = chr(c)
    if ch.isdigit():
        return 13
    if ch in "abcdefABCDEF":
        return 12
    if ch.isalpha():
        return 11
    if ch in "!#$%&'*+-.^_`|~":
        return 10
    if ch == ":":
        return 7
    if ch == ";":
        return 8
    return 6


def hexv(c):
    ch = chr(c)
    if ch in "0123456789":
        return c - 48
    if ch in "abcdef":
        return c - 87
    if ch in "ABCDEF":
        return c - 55
    return 16


def declarations():
    a = 'const HTTP_CLASS: string = "' + "".join("\\x%02x" % cls(c) for c in range(256)) + '";'
    b = 'const HTTP_HEXV: string = "' + "".join("\\x%02x" % hexv(c) for c in range(256)) + '";'
    return a, b


def main():
    a, b = declarations()
    if "--check" in sys.argv[1:]:
        src = open(os.path.join(ROOT, "stdlib", "http.or"), encoding="utf-8").read()
        for d in (a, b):
            if d not in src:
                sys.exit("stdlib/http.or: %s is not the generated table (run tools/gen_http_tables.py)" % d.split(":")[0])
        print("stdlib/http.or tables are current")
        return
    print(a)
    print(b)


if __name__ == "__main__":
    main()
