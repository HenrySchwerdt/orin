# std:time — monotonic observations and deadlines (unstable)

The wall-clock API `nowMillis(clock): int` remains Unix-epoch milliseconds and can jump. Use the
separate monotonic types below for elapsed time and deadlines. These additions retain the unstable
I/O status of [ADR-0027](decisions/0027-stage-a-root-capabilities.md); they do not freeze std I/O.

```typescript
type MonotonicInstant = { millis: int; };
type Deadline = { at: MonotonicInstant; };
type TimeErrorKind = ClockUnavailable | InvalidInstant | NegativeDuration | TimeOverflow | ReversedInstants;
type TimeError = { kind: TimeErrorKind; };

monotonicNow(clock: ClockGrant): Result<MonotonicInstant, TimeError>
elapsed(start: MonotonicInstant, end: MonotonicInstant): Result<Duration, TimeError>
deadlineAfter(start: MonotonicInstant, delay: Duration): Result<Deadline, TimeError>
remaining(deadline: Deadline, now: MonotonicInstant): Result<Duration, TimeError>
isExpired(deadline: Deadline, now: MonotonicInstant): Result<bool, TimeError>
timeErrorMessage(error: TimeError): string
```

Every quantity is a whole millisecond. `MonotonicInstant` has arbitrary origin, not a Unix epoch.
Use observations from the same process/clock domain; do not persist them across restarts or compare
them to wall-clock timestamps. Platform suspend behavior is not standardized by this API. Distinct
record types reject accidentally passing a wall-clock `int` into a deadline helper. These are ordinary
public value records, not opaque provenance proofs: explicit construction is possible, including for
deterministic tests, and callers are responsible for the origin of explicitly constructed values.
All helpers reject negative instant fields, including a negative deadline field.

`monotonicNow` requires a live `ClockGrant`, from `useClock` or `useHost`. It returns
`Err(TimeError { kind: ClockUnavailable })` when the native read fails, has invalid fields or cannot
fit nonnegative i64 milliseconds. It never substitutes a wall clock, zero or a stale observation.
Denied, forged, wrong-family and revoked grants retain the existing trap behavior; permission
validation precedes the clock read. The internal `std:clock.monotonicMillis` binding uses `Option<int>`;
the public API maps `None` to the structured error. A legitimate zero observation is `Ok`, not failure.

The other helpers are pure: the caller supplies `now`, so they neither read a clock nor need a grant.
`elapsed` rejects reversed observations with `ReversedInstants`, rather than returning a negative
span. `deadlineAfter` rejects a negative delay (`NegativeDuration`) and checks addition before
performing it (`TimeOverflow`). Zero delay expires at the supplied start. `remaining` returns zero
at or after expiry, otherwise a nonnegative `Duration`; `isExpired` is inclusive at equality. Errors
on negative records are `InvalidInstant`. Validation and comparisons precede arithmetic, so valid
nonnegative i64 endpoints cannot overflow subtraction. Existing `Duration` constructors/arithmetic
keep their original trapping overflow behavior; an overflow while building a duration precedes
these helpers and is not converted to a `TimeError`.

```typescript
import { Host, useClock } from "std:host";
import { monotonicNow, deadlineAfter, milliseconds, isExpired } from "std:time";

function main(host: Host): void {
  useClock(host, clock => {
    const start = monotonicNow(clock).unwrap();
    const deadline = deadlineAfter(start, milliseconds(250)).unwrap();
    const now = monotonicNow(clock).unwrap();
    console.log(isExpired(deadline, now).unwrap().toString());
  });
}
```

`unwrap` is only for concise examples: programs that need to continue after a failed clock read
should inspect the `Result` and choose their own failure policy. Every operation has O(1) time and
bounded O(1) value/Result allocation under the current object representation; none grows a buffer
or waits. `timeErrorMessage` returns a constant nonempty string. The clock read is impure and is
reported as `Clock.Now INPUT ClockGrant`; it cannot be used as a pure contract expression. The
arithmetic helpers remain usable without I/O authority.

## Native boundary and evidence

This reuses `orin_platform_monotonic_millis`; no new L0 primitive is introduced. Its contract now
specifies `-1` on failed `clock_gettime`, invalid timespec fields or millisecond conversion overflow;
success is in `0..INT64_MAX`. The OS read is checked before accessing the output fields. The existing
network caller checks this sentinel and traps with `monotonic clock unavailable`: its existing
`int` API does not gain a Result, and a failed clock cannot silently disable a connection deadline.
The wall-clock primitive is unchanged. Platform code is **981/1,000 lines** by the existing
`tools/verify_platform.sh` rule at this implementation; no budget increase or source compression
was used to make room.

`tools/test_time.py --orinc build/bootstrap/orin2` exercises deterministic native injection (failed
read, zero, negative seconds, negative/out-of-range nanoseconds, exact i64 boundary and overflow),
grant revocation/wrong-family/denial, network failure, and C/LLVM with contracts on/off under
ASan/UBSan. The normal smoke allows equal samples and tests no tight elapsed-time bound. Pure
vectors cover zero, maximum, overflow, negative and reversed inputs. Compiler errors reject wall
mixing, the wrong grant family and impure contracts; independent MIR tests reject a read after
revocation. These are implementation tests/contracts, not a proof of OS clock behavior or an
end-to-end correctness theorem.

## Sleep is deferred

There is no public sleep API in this change. The L0 closed list has no sleep function; the
`nanosleep` call inside bounded process execution is private implementation detail, and monitor
waiting has different locking/notification semantics. Shelling out to `sleep`, polling sockets or
busy-spinning would misuse authority or add unsupported semantics.

A future proposal needs a contracted L0 sleep boundary before a public `sleepFor(clock, duration)`:
validate the ClockGrant before any success/error fast path; reject negative and excessively large
requests as ordinary structured errors; define zero as a no-op; return OS failures explicitly; and
specify EINTR/retry behavior without inventing cancellation. A proposed initial request cap is
86,400,000 ms (one day), requiring a decision rather than being promised here. Sleep would block
only the calling OS thread and could overshoot under scheduling/suspend; a bounded requested delay
is not a hard upper bound on return time. Use native relative nanosecond waits/remainders, not a
floored public millisecond deadline that could undersleep. It needs an explicit control effect
(such as `Clock.Sleep`), native interruption tests, and independently bounded smoke tests without
strict timing assertions. With 19 code lines of L0 headroom, the complete implementation and header
must be measured before approval; no budget expansion is authorized. No scheduler, async syntax,
select, cancellation or future async wakeup semantics are implied by this monotonic foundation.
