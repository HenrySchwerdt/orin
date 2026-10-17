# 10. Concurrency

Orin has no shared mutable memory. Tasks run in parallel on operating-system threads and share nothing: a value that goes
to a task is moved or copied, so there are no data races to reason about. The tools live in `std:task`.

## The program

<!-- file: examples/tutorial/10-concurrency.or -->
```ts
// Concurrency with std:task: tasks, joins, channels and parallel pipelines.
import { scope, spawn, channel } from "std:task";

function sumRange(lo: int, hi: int): int {
  let total = 0;
  let i = lo;
  while (i < hi) {
    total += i;
    i += 1;
  }
  return total;
}

function main(): void {
  // 1. Two tasks; scope() returns only when every task started inside has ended.
  const total = scope(s => {
    const a = spawn(s, () => sumRange(0, 500000));
    const b = spawn(s, () => sumRange(500000, 1000000));
    return a.join() + b.join();
  });
  console.log("sum of 0..999999 = " + total.toString());

  // 2. A bounded channel: a producer task sends, the main task receives.
  const ch = channel<int>(4);
  const received = scope(s => {
    const producer = spawn(s, () => {
      let i = 1;
      while (i <= 5) {
        ch.tx.send(i * i);
        i += 1;
      }
      ch.tx.close();
      return 0;
    });
    let sum = 0;
    while (true) {
      const m = ch.rx.recv();
      if (m.isNone()) {
        break;
      }
      console.log("got " + m.unwrap().toString());
      sum += m.unwrap();
    }
    producer.join();
    return sum;
  });
  console.log("received total " + received.toString());

  // 3. A parallel pipeline over an array: same result as the sequential chain.
  let xs: int[] = [];
  let i = 1;
  while (i <= 1000) {
    xs.push(i);
    i += 1;
  }
  const squares = xs.parallel().filter(x => x % 7 == 0).map(x => x * x).toArray();
  console.log("multiples of 7: " + squares.length.toString() + ", last square " + squares[squares.length - 1].toString());
}
```

Output (the same on every run, because the order is fixed by `join` and by the channel):

<!-- file: examples/tutorial/10-concurrency.out -->
```text
sum of 0..999999 = 499999500000
got 1
got 4
got 9
got 16
got 25
received total 55
multiples of 7: 142, last square 988036
```

## What is in it

**Scopes and tasks.** `scope(s => { ... })` is *structured*: when it returns, every task started inside has ended.
`spawn(s, () => expr)` starts a task and returns a `TaskHandle<T>`; `handle.join()` waits for the result. The closure
captures a snapshot of the variables it uses (they are moved or copied into the task), and cannot capture the scope or a
resource such as a file or grant. A task that traps does not take the process down at once; `join` turns it into a trap of
the joiner (`task panicked: ...`), and a panic that nobody joins is reported when the scope ends, so none is lost.

**Channels.** `channel<int>(4)` makes a bounded queue with a sender `ch.tx` and a receiver `ch.rx`, both usable from any
task. `send` blocks while the queue is full and returns `false` if the channel was closed; `recv` blocks while it is
empty and returns `None` once the sender has called `close()` and everything has been taken. That is how the receiver
above knows to stop.

**Parallel pipelines.** `xs.parallel()` turns an array pipeline (`filter`, `map`, `reduce`, `find`, `some`, `every`,
`toArray`) into one that runs on a pool of worker threads. For a pure function the result equals the sequential chain, so
you can add or remove `.parallel()` to compare. A parallel integer `reduce` with `+` warns (W0481) because partial sums
may overflow in a different order than the sequential fold.

**More.** Timed operations (`recvTimeout`, `joinTimeout`, `sleep`), `select` over several receivers, `parallelMap`, and
delegating a file grant to a task are described in [concurrency.md](../concurrency.md). `std:task` is marked unstable
(stage 0); there is no `async`/`await` yet.

## Try it

Start a third task in the first `scope` that sums `1000000` to `1500000`, and join it too. Then change the channel
capacity to `1` and check that the output does not change.

Reference: [concurrency surface](../reference/08-concurrency.md), [concurrency guide](../concurrency.md).

You have reached the end of the tutorial. Good places to continue: the [language reference](../reference/README.md), the
[standard library overview](../std.md), and the programs in [`examples/`](../../examples/), which include an HTTP server
and a JSON codec.
