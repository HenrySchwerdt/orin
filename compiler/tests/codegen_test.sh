#!/bin/sh
# Compile and run the C files produced by compiler/tests/codegen_main.or (build/cg/*.c) and
# compare stdout with the expected output embedded below.
# Usage (repo root): orinb build compiler/tests/codegen_main.or -o build/codegen_main &&
#   ./build/codegen_main && sh compiler/tests/codegen_test.sh [extra cc flags, e.g. -fsanitize=address,undefined]
cd "$(dirname "$0")/../.." || exit 1
CC=${CC:-cc}
FLAGS="${*:--O1}"
export ASAN_OPTIONS=detect_leaks=0
pass=0
fail=0

check() {
  name=$1
  expected=$2
  if ! $CC $FLAGS -w -I runtime "build/cg/$name.c" runtime/orin_runtime.c -o "build/cg/$name" 2>"build/cg/$name.err"; then
    echo "FAIL $name (cc)"; head -20 "build/cg/$name.err"; fail=$((fail + 1)); return
  fi
  actual=$("./build/cg/$name" 2>"build/cg/$name.err")
  if [ "$actual" = "$expected" ] && [ ! -s "build/cg/$name.err" ]; then
    echo "ok   $name"; pass=$((pass + 1))
  else
    echo "FAIL $name"; echo "--- expected"; echo "$expected"; echo "--- actual"; echo "$actual"
    cat "build/cg/$name.err"; fail=$((fail + 1))
  fi
}

check hello 'hello'

check arith '14
-3
-2
5
true
false'

check loop '25
610'

check records '10
1
42
2
10
7
bob!'

check union '12
15
0
one
two
many
2
0
77
not circle'

check try '11
neg
42
none
7
true'

check forof 'a,b,c,
a-b-c
28
4
4
3
4
20
a'

check strings 'say "hi"
yes
true
65
y!
15'

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
