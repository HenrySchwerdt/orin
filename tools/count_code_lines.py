#!/usr/bin/env python3
"""Count the CODE lines of C files: lines that are not blank and not entirely inside a comment (ADR-0030: the L0 budget
counts code, not contracts). Prints the total of all files given; `-v` prints one line per file."""
import re
import sys


def code_lines(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return sum(1 for line in text.splitlines() if line.strip())


def main(argv):
    verbose = "-v" in argv
    files = [a for a in argv if a != "-v"]
    total = 0
    for f in files:
        with open(f, encoding="utf-8") as fh:
            n = code_lines(fh.read())
        if verbose:
            print("%6d  %s" % (n, f))
        total += n
    print(total)


if __name__ == "__main__":
    main(sys.argv[1:])
