# URL checks and microbenchmark

From the repository root after bootstrapping:

```sh
python3 bench/url/check.py --orin build/bootstrap/orin2
python3 bench/url/check.py --orin build/bootstrap/orin2 --sanitize --skip-bench
```

Needs clang for both backends and Python 3. Each assertion build has a 180 second timeout. The script
creates an ordinary-main harness from every `@Test` group in `tests/std/url_test.or`, then runs the
same assertions with C and LLVM, with contracts on and off. Builds go into ignored `build/url/`.
Sanitizer mode enables ASan/UBSan for both backends (leak detection disabled by default).

The microbenchmark runs three times per backend with contracts off and clang -O2. It builds a mixed
ASCII/UTF-8 input of 3,584 / 14,336 / 57,344 bytes, then performs 64 percent encode/decode and two-pair
query parse/stringify cycles at each size. Input construction is outside the timed region; decoded
and serialized lengths contribute to an observable checksum. Timing uses the clock grant, in whole
milliseconds. Fourfold input growth should show approximately linear runtime beyond timer and startup
noise. This is a scaling smoke test, not a statistical performance guarantee or allocation census.
See the PR validation notes for measured results on the implementation machine.
