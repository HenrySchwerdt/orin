#!/usr/bin/env python3
"""Independent JSON Pointer vectors, backend/contract/sanitizer checks and scaling.
Run: python3 tools/check_jsondecode.py [--orinc build/bootstrap/orin2]
"""
import argparse
import os
from pathlib import Path
import random
import re
import statistics
import time

import check_jsonvalue as harness

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/jsondecode"
harness.OUT = OUT


def oracle_cases():
    rng = random.Random(20261016)
    entries = []
    for i in range(120):
        path = [rng.choice(["", "a/b~", "~1/~0", "é", "1", "a.b"])
                if rng.randrange(2) else rng.randrange(3) for _ in range(i % 7)]
        value = 'ValueNull'
        for part in reversed(path):
            if isinstance(part, str):
                value = 'ValueObject([JsonMember { key: ' + harness.literal(part) + ', value: ' + value + ' }])'
            else:
                value = 'ValueArray([' + ','.join(['ValueBool(false)'] * part + [value]) + '])'
        navigation = 'let c = root(' + value + ');\n'
        for part in path:
            navigation += ('c = requiredField(c,' + harness.literal(part) + ').unwrap();\n'
                           if isinstance(part, str) else
                           f'c = decodeArray(c).unwrap()[{part}];\n')
        expected = ''.join('/' + str(p).replace('~', '~0').replace('/', '~1') for p in path)
        structure = f'assertEqUsize(e.path.length,{len(path)},"path length");\n'
        for j, p in enumerate(path):
            pattern = 'Key(s) => s == ' + harness.literal(p) if isinstance(p, str) else f'Index(n) => n == {p}'
            structure += f'assert(match(e.path[{j}]) {{ {pattern}, _ => false }},"structural segment");\n'
        entries.append('''{
''' + navigation + f'''const e = decodeString(c).unwrapErr();
error(e,"type",{harness.literal(expected)});
{structure}
assertEqString(e.expected,"string","fixed expected category");
assertEqString(e.actual,"null","fixed actual category");
}}
''')
    return entries


BENCHMARK = '''import { Host, useProcess } from "std:host";
import { args } from "std:process";
import { JsonValue, JsonMember, defaultLimits } from "std:json";
import { decodeRoot, requiredField, decodeArray, cursorPath } from "std:json/decode";
import { assertEqUsize } from "std:test";
function main(host: Host): void {
  useProcess(host, proc => {
    const a=args(proc); const n=parseInt(a[0]).unwrap().toUsize(); const mode=a[1];
    let l=defaultLimits(); l.maxNodes=n*4+1000; l.maxContainerItems=n+1000;
    l.maxDecodedStringBytes=n*32+1000; l.maxDepth=200;
    let checksum:usize=0;
    if (mode == "root") {
      let values:JsonValue[]=[]; let i:usize=0;
      while(i<n){ values.push(ValueString("abcdef")); i+=1; }
      const tree=ValueArray(values); i=0;
      while(i<40){ checksum+=decodeArray(decodeRoot(tree,l).unwrap()).unwrap().length; i+=1; }
      assertEqUsize(checksum,n*40,"root checksum");
    } else if (mode == "lookup") {
      let fields:JsonMember[]=[]; let i:usize=0;
      while(i<n){ fields.push(JsonMember { key:"k"+i.toString(), value:ValueNull }); i+=1; }
      const c=decodeRoot(ValueObject(fields),l).unwrap(); const key="k"+(n-1).toString(); i=0;
      while(i<200){ checksum+=cursorPath(requiredField(c,key).unwrap()).length; i+=1; }
      assertEqUsize(checksum,200,"lookup checksum");
    } else {
      let values:JsonValue[]=[]; let i:usize=0;
      while(i<1000){ values.push(ValueNull); i+=1; }
      let tree=ValueArray(values); i=0;
      while(i<n){ tree=ValueArray([tree]); i+=1; }
      let c=decodeRoot(tree,l).unwrap(); i=0;
      while(i<n){ c=decodeArray(c).unwrap()[0]; i+=1; }
      i=0; while(i<20){ const items=decodeArray(c).unwrap(); checksum+=cursorPath(items[999]).length; i+=1; }
      assertEqUsize(checksum,(n+1)*20,"array depth checksum");
    }
    console.log(checksum.toString());
  });
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--orinc', default='build/bootstrap/orin2')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--bench-only', action='store_true', help='reuse a completed correctness run')
    mode.add_argument('--skip-bench', action='store_true', help='run vectors/oracles and backend checks only')
    opts = parser.parse_args()
    orinc = (ROOT / opts.orinc).resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    tests = (ROOT / 'tests/std/jsondecode_test.or').read_text()
    names = re.findall(r'@Test\s+function (\w+)\(', tests)
    if not names:
        raise RuntimeError("no jsondecode tests discovered")
    entries = oracle_cases()
    source = OUT / 'oracle.or'
    source.write_text(tests.replace('@Test', '') + '\nfunction main(): void {\n' +
                      ''.join(name + '();\n' for name in names) + ''.join(entries) +
                      'console.log("jsondecode oracle passed");\n}\n')
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
    matrix = [] if opts.bench_only else [('c', False, False), ('c', True, False),
                                          ('llvm', False, False), ('llvm', True, False),
                                          ('c', True, True)]
    for backend, contracts, sanitize in matrix:
        binary = harness.build(orinc, source, backend, contracts, sanitize)
        assert harness.run([binary], env) == 'jsondecode oracle passed\n'
        print(f'PASS {len(entries)} independent structural/pointer vectors + {len(names)} test groups: '
              f'{backend} contracts={contracts} sanitizers={sanitize}', flush=True)
    if opts.skip_bench:
        return
    source = OUT / 'benchmark.or'
    source.write_text(BENCHMARK)
    for backend in ['c', 'llvm']:
        binary = harness.build(orinc, source, backend)
        for mode, sizes in [('root', [1000, 4000, 16000]),
                            ('lookup', [1000, 4000, 16000]), ('depth', [10, 40, 160])]:
            for n in sizes:
                expected = n*40 if mode == 'root' else 200 if mode == 'lookup' else (n+1)*20
                elapsed = []
                for _ in range(3):
                    start = time.perf_counter()
                    assert harness.run([binary, n, mode]) == f'{expected}\n'
                    elapsed.append(time.perf_counter() - start)
                print(f'BENCH {backend} mode={mode} n={n} median_s={statistics.median(elapsed):.6f} '
                      f'checksum={expected}', flush=True)


if __name__ == '__main__':
    main()
