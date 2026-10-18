/*
 * Orin L0 platform layer (spec 19 section 2, ADR-0013): the CLOSED LIST of primitives through which
 * the runtime (runtime/core/) and the code emitted by the compiler reach the operating system and the
 * C library. Nothing outside runtime/platform/ may call libc directly (tools/check_platform_boundary.sh).
 * Adding a function needs an ADR.
 *
 * Rules for this layer: no data structures (one opaque OS handle type, `orin_platform_stream`, excepted),
 * no global state beyond argc/argv, the stdout lock and the thread / monitor tables, no knowledge of Orin
 * objects. Hard budget: runtime/platform/ (sources + header, without tests) stays <= 1,000 CODE lines (blank lines,
 * comments and contract blocks do not count: tools/verify_platform.sh). Thread-safe except where said otherwise
 * (ADR-0017 stage 0: threads and monitors below; the network functions, ADR-0033, act on caller-owned handles).
 *
 * CONTRACT FORMAT. Every function carries one ACSL-style block, machine readable (a leading
 * slash-star-at marker; clauses `requires`, `ensures`, `assigns`, each ending in `;`):
 *     requires <precondition the CALLER must establish; violating it is undefined behaviour>;
 *     ensures  <postcondition the implementation establishes>;
 *     assigns  <memory and external state the function may modify; `\nothing` = none>;
 * Extra ACSL names used: \valid(p + (0..n-1)) = n writable bytes at p, \valid_read for readable
 * bytes, \result, \old, \separated, and the pseudo locations `\stdout`, `\stderr`, `\stdin`,
 * `\fs` (the file system) and `\process` (exit status, environment, arguments). Prose inside a
 * clause is informal. The blocks are written so that Frama-C/WP can be tried on them; today they
 * are checked by bounded model checking and tests (tools/verify_platform.sh, docs/formal.md
 * "L0 platform layer"), not proved.
 *
 * Status labels (spec 07): memory and fmt primitives = bounded-verified (CBMC); I/O, process and
 * file primitives = tested only (they wrap the OS).
 *
 * Errors: functions that can fail with an OS error return 0 on success or a positive errno-style
 * code; orin_platform_error_message turns a code into text.
 */
#ifndef ORIN_PLATFORM_H
#define ORIN_PLATFORM_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORIN_PLATFORM_STDOUT 1  /* buffered */
#define ORIN_PLATFORM_STDERR 2  /* writing flushes stdout first, then flushes stderr */
#define ORIN_PLATFORM_EINVAL 22 /* path contains a NUL byte (same value on Linux and macOS) */
#define ORIN_PLATFORM_ENOMEM 12
#define ORIN_PLATFORM_EBUSY 16
#define ORIN_PLATFORM_WAIT_TIMEOUT 1 /* orin_platform_monitor_wait_until: the deadline passed */
#define ORIN_PLATFORM_EDEADLK EDEADLK /* a monitor locked twice by the same thread (35 on Linux, 11 on macOS) */

/* ================================================================ memory
 * Defined inline in this header so the hot paths of the runtime keep inlining them; the
 * contracts are identical to those of out-of-line functions. */

/*@ ensures \result == NULL || \valid((char *)\result + (0..(n ? n : 1) - 1));
    ensures \result != NULL ==> (size_t)\result % 16 == 0;   (suitably aligned for any object)
    assigns \nothing; */
static inline void *orin_platform_alloc(size_t n) { return malloc(n ? n : 1); }

/*@ requires p == NULL || p was returned by alloc/realloc and not yet freed;
    ensures \result == NULL ==> p is still valid and unchanged (nothing is freed);
    ensures \result != NULL ==> \valid((char *)\result + (0..(n ? n : 1) - 1))
              && the first min(\old(size of p), n) bytes equal the old contents && p is dead;
    assigns *p; */
static inline void *orin_platform_realloc(void *p, size_t n) { return realloc(p, n ? n : 1); }

/*@ requires p == NULL || p was returned by alloc/realloc and not yet freed;
    ensures p is dead;
    assigns *p; */
static inline void orin_platform_free(void *p) { free(p); }

/*@ requires n == 0 || (\valid((char *)dst + (0..n-1)) && \valid_read((char *)src + (0..n-1)));
    requires \separated((char *)dst + (0..n-1), (char *)src + (0..n-1));
    ensures \result == dst && dst[0..n-1] == \old(src[0..n-1]);
    assigns ((char *)dst)[0..n-1]; */
static inline void *orin_platform_mem_copy(void *dst, const void *src, size_t n) {
    return n ? memcpy(dst, src, n) : dst;
}

/*@ requires n == 0 || (\valid((char *)dst + (0..n-1)) && \valid_read((char *)src + (0..n-1)));
    ensures \result == dst && dst[0..n-1] == \old(src[0..n-1]);   (regions may overlap)
    assigns ((char *)dst)[0..n-1]; */
static inline void *orin_platform_mem_move(void *dst, const void *src, size_t n) {
    return n ? memmove(dst, src, n) : dst;
}

/*@ requires n == 0 || \valid((char *)p + (0..n-1));
    ensures \result == p && p[0..n-1] == (unsigned char)c;
    assigns ((char *)p)[0..n-1]; */
static inline void *orin_platform_mem_set(void *p, int c, size_t n) { return n ? memset(p, c, n) : p; }

/*@ requires n == 0 || (\valid_read((char *)a + (0..n-1)) && \valid_read((char *)b + (0..n-1)));
    ensures \result == 0 <==> a[0..n-1] == b[0..n-1];
    ensures \result < 0 <==> the first differing byte (as unsigned char) is smaller in a;
    assigns \nothing; */
static inline int orin_platform_mem_cmp(const void *a, const void *b, size_t n) {
    return n ? memcmp(a, b, n) : 0;
}

/*@ requires hn == 0 || \valid_read((char *)hay + (0..hn-1));
    requires nn == 0 || \valid_read((char *)needle + (0..nn-1));
    ensures nn == 0 ==> \result == hay;
    ensures nn > 0 && \result != NULL ==> hay <= \result && \result + nn <= hay + hn
              && \result[0..nn-1] == needle[0..nn-1]
              && no smaller offset in [0, \result - hay) matches;       (first occurrence)
    ensures \result == NULL ==> nn > 0 && no offset in [0, hn - nn] matches (none at all if nn > hn);
    assigns \nothing; */
const void *orin_platform_mem_find(const void *hay, size_t hn, const void *needle, size_t nn);

/* ================================================================ number formatting (pure) */

/*@ requires \valid(buf + (0..19));          (at most 20 characters: "-9223372036854775808")
    ensures 1 <= \result <= 20 && buf[0..\result-1] is the decimal text of v with a leading '-'
              for negative v, no leading zeros, no sign for v >= 0, and no terminating NUL;
    assigns buf[0..19]; */
size_t orin_platform_fmt_i64(char *buf, int64_t v);

/*@ requires \valid(buf + (0..19));
    ensures 1 <= \result <= 20 && buf[0..\result-1] is the decimal text of v without leading zeros;
    assigns buf[0..19]; */
size_t orin_platform_fmt_u64(char *buf, uint64_t v);

/* ================================================================ process */

/*@ requires argc >= 0 && (argc == 0 || argv[0..argc-1] are NUL-terminated strings that stay valid);
    ensures stdout is fully buffered (64 KiB) and the arguments are recorded;
    assigns \stdout, \process; */
void orin_platform_init(int argc, char **argv);

/*@ ensures \result == the argc given to init (0 before init);
    assigns \nothing; */
int orin_platform_arg_count(void);

/*@ requires 0 <= i < orin_platform_arg_count();
    ensures \result == argv[i] of init (NUL-terminated, owned by the process);
    assigns \nothing; */
const char *orin_platform_arg(int i);

/*@ requires name is NUL-terminated;
    ensures \result == NULL || \result is a NUL-terminated string owned by the process;
    assigns \nothing; */
const char *orin_platform_getenv(const char *name);

/*@ ensures \result == 0 ==> fn runs once at normal process end (exit or return from main),
              in reverse registration order;
    assigns \process; */
int orin_platform_at_exit(void (*fn)(void));

/*@ ensures buffered stdout is flushed, then the process ends with status (code & 0xff);
    ensures \false;                                        (never returns)
    assigns \stdout, \process; */
void orin_platform_exit(int code) __attribute__((noreturn));

/*@ ensures the process ends abnormally (SIGABRT), no flush;
    ensures \false;
    assigns \process; */
void orin_platform_abort(void) __attribute__((noreturn));

/*@ requires n == 0 || cmd[0..n-1] readable;     (bytes after the first NUL, if any, are ignored)
    ensures stdout is flushed first;
    ensures \result >= 0 ==> \result is the exit status of /bin/sh -c cmd;
    ensures \result == -1 ==> the shell could not be started, was killed by a signal, or no memory;
    assigns \stdout, \process; */
int64_t orin_platform_shell(const char *cmd, size_t n);

/*@ requires n == 0 || cmd[0..n-1] readable; (first NUL ends command, as with shell)
    requires the caller does not reap this call's child or change SIGCHLD during the call;
    ensures non-default SIGCHLD disposition or SA_NOCLDWAIT ==> \result == -1 and no child is started;
    ensures seconds <= 0 ==> \result == -1 and no child is started;
    ensures \result >= 0 ==> \result is the shell exit status (0..255);
    ensures \result == -2 ==> the monotonic deadline expired;
    ensures \result == -1 ==> invalid duration, memory, spawn, signal or OS error;
    ensures the direct child is reaped and its process group signaled SIGKILL on completion;
    assigns \stdout, \process; */
int64_t orin_platform_shell_timeout(const char *cmd, size_t n, int64_t seconds);

/*@ ensures \result is the wall-clock time in milliseconds since the Unix epoch (CLOCK_REALTIME);
    assigns \nothing; */
int64_t orin_platform_now_millis(void);


/* ================================================================ threads and monitors (ADR-0017 stage 0)
 * The only primitives of concurrency, and they stay in C: create / join / end an operating-system thread, and a
 * MONITOR = a mutex, a condition variable and an array of 64-bit words that can be read and written only while
 * the calling thread holds the mutex. Everything above them (tasks, scopes, channels, results) is Orin (std:task).
 * Handles are 64-bit values `generation << 32 | (index + 1)` and are VALIDATED on every call: a stale (already freed or
 * joined), forged or foreign handle is refused with ORIN_PLATFORM_EINVAL, never dereferenced; records are recycled, not
 * freed, so a lookup never touches freed memory. Contract status: tested only (runtime/platform/tests/platform_test.c, plain,
 * ASan+UBSan and ThreadSanitizer; tools/verify_platform.sh); CBMC cannot model threads. All other functions of this
 * layer may now be called from several threads at the same time unless said otherwise; the stdout buffer is serialised
 * inside orin_platform_write / write_line / flush. */

/*@ ensures \result >= 1, unique among all threads of the process, constant for the calling thread (the first
            caller, normally the main thread, gets 1);
    assigns \nothing (a thread-local cache); */
uint64_t orin_platform_thread_id(void);

/*@ ensures \result >= 1: the number of processors online (1 when the OS cannot tell); a hint for how many worker threads
            a parallel computation should start (ADR-0039), never a limit;
    assigns \nothing; */
uint64_t orin_platform_cpu_count(void);

/*@ requires entry is a function that may run on another thread; arg is whatever entry expects (the layer never reads it);
    ensures \result == 0 ==> no thread was started (limit of 65,536 live threads or the OS refused) and nothing needs cleaning;
    ensures \result > 0 ==> a new thread runs entry(arg); the handle must be passed to orin_platform_thread_join exactly once;
    assigns \process; */
int64_t orin_platform_thread_create(void (*entry)(void *), void *arg);

/*@ ensures \result == ORIN_PLATFORM_EINVAL ==> h is not a live, not yet joined handle (stale, forged, joined twice,
            being joined by another thread); nothing happens;
    ensures \result == 0 ==> the thread has ended (returned from entry or called orin_platform_thread_exit), *arg is the
            `arg` given to create, all of the thread's writes are visible to the caller, h is dead afterwards;
    assigns *arg, \process; */
int orin_platform_thread_join(int64_t h, void **arg);

/*@ requires the calling thread was started by orin_platform_thread_create;
    ensures every monitor the calling thread holds is unlocked (a thread that ends abnormally never leaves a lock held);
    ensures the thread ends and is joinable; never returns;
    assigns \process; */
void orin_platform_thread_exit(void) __attribute__((noreturn));

/*@ ensures \result == 0 ==> no monitor could be made (limit of 262,144 live monitors, or no memory);
    ensures \result > 0 ==> a monitor with nwords words, all 0, unlocked; free it with orin_platform_monitor_free;
    assigns \process; */
int64_t orin_platform_monitor_new(size_t nwords);

/*@ ensures \result == ORIN_PLATFORM_EINVAL ==> h is stale or forged;
    ensures \result == ORIN_PLATFORM_EBUSY ==> the monitor is locked or a thread waits on it; nothing happens;
    ensures \result == 0 ==> h is dead (its words are gone), a later use of h returns ORIN_PLATFORM_EINVAL;
    assigns the monitor; */
int orin_platform_monitor_free(int64_t h);

/*@ ensures \result == ORIN_PLATFORM_EINVAL ==> h is stale or forged;
    ensures \result == ORIN_PLATFORM_EDEADLK ==> the calling thread already holds the monitor (no relock);
    ensures \result == 0 ==> the calling thread holds the monitor (blocking until it was free);
    assigns the monitor; */
int orin_platform_monitor_lock(int64_t h);

/*@ ensures \result == ORIN_PLATFORM_EINVAL ==> h is stale or forged, or the calling thread does not hold it;
    ensures \result == 0 ==> the monitor is free; the caller's writes are visible to the next thread that locks it;
    assigns the monitor; */
int orin_platform_monitor_unlock(int64_t h);

/*@ requires as unlock; cond is 0 or 1 (a monitor has two condition queues);
    ensures \result == 0 ==> the caller released the monitor, slept on queue `cond` until another thread notified that
            queue (or spuriously), and holds the monitor again: re-check the condition in a loop;
    ensures \result == ORIN_PLATFORM_EINVAL ==> as unlock, or cond is not 0 or 1; assigns the monitor; */
int orin_platform_monitor_wait(int64_t h, int cond);

/*@ requires as wait; deadline_ms >= 0 is an ABSOLUTE instant on the clock of orin_platform_monotonic_millis (CLOCK_MONOTONIC),
            so retries and nested waits cannot stretch it (ADR-0017 Addendum B section 5);
    ensures \result == 0 ==> as wait (notified or spuriously woken before the deadline: re-check the condition and call again
            with the SAME deadline);
    ensures \result == ORIN_PLATFORM_WAIT_TIMEOUT ==> the deadline has passed (also when it had passed before the call, then
            without sleeping); the caller released the monitor while waiting and holds it again: re-check the condition once more,
            a notification that raced with the timeout is not lost;
    ensures \result == ORIN_PLATFORM_EINVAL ==> as wait, or deadline_ms < 0; assigns the monitor;
    Linux: pthread_cond_timedwait on a condition variable created with CLOCK_MONOTONIC (pthread_condattr_setclock).
    macOS has no condattr_setclock: the remaining time is computed from the same clock and passed to
    pthread_cond_timedwait_relative_np (a wait never ends earlier than the deadline except by a notification). */
int orin_platform_monitor_wait_until(int64_t h, int cond, int64_t deadline_ms);

/*@ requires ms >= 0 and sec, nsec valid; ensures \result == 0 ==> *sec * 1000 + *nsec / 1000000 == ms, 0 <= *nsec < 10^9
            (a struct timespec, exactly: no rounding, no overflow); \result == ORIN_PLATFORM_EINVAL ==> ms < 0, nothing written;
    assigns *sec, *nsec; */
int orin_platform_millis_split(int64_t ms, int64_t *sec, int64_t *nsec);

/*@ requires the caller holds the monitor and cond is 0 or 1;
    ensures \result == 0 ==> all threads waiting on queue `cond` (all != 0) or one of them, if any (all == 0), wake up
            (after the caller unlocks);
    ensures \result == ORIN_PLATFORM_EINVAL ==> as wait; assigns \nothing; */
int orin_platform_monitor_notify(int64_t h, int cond, int all);

/*@ requires the caller holds the monitor; ensures \result == 0 ==> *out is word i; \result == ORIN_PLATFORM_EINVAL ==>
            stale handle, lock not held, or i >= the number of words; assigns *out; */
int orin_platform_monitor_get(int64_t h, size_t i, uint64_t *out);

/*@ requires the caller holds the monitor; ensures \result == 0 ==> word i is v; \result == ORIN_PLATFORM_EINVAL ==> as get;
    assigns the monitor's word i; */
int orin_platform_monitor_set(int64_t h, size_t i, uint64_t v);

/*@ requires the caller holds the monitor; ensures \result == 0 ==> the monitor has nwords >= its old size words, the old
            ones unchanged, the new ones 0; \result == ORIN_PLATFORM_EINVAL ==> as get or nwords is smaller than now;
            \result == ORIN_PLATFORM_ENOMEM ==> nothing changed; assigns the monitor; */
int orin_platform_monitor_grow(int64_t h, size_t nwords);

/*@ ensures the calling thread holds the one lock of the runtime's own shared tables (transfer slots, the statistics of
            finished tasks); hold it only for a few instructions and never call a trapping function while holding it;
    assigns \process; */
void orin_platform_runtime_lock(void);

/*@ requires the caller holds the runtime lock; ensures it is released; assigns \process; */
void orin_platform_runtime_unlock(void);

/* ================================================================ floating point text */

/*@ requires cap >= 32 && buf[0..cap-1] writable && 0 <= prec <= 17 && x is finite;
    ensures buf holds the NUL-terminated C "%.*e" rendering of x with prec fraction digits;
    assigns buf[0..cap-1]; */
void orin_platform_double_to_exp(char *buf, size_t cap, int prec, double x);

/*@ requires s is NUL-terminated and matches the decimal float grammar of strtod;
    ensures \result is the correctly rounded value of s (rounded to float first when is_f32);
    assigns \nothing; */
double orin_platform_parse_double(const char *s, int is_f32);

/* ================================================================ byte I/O */

/*@ requires stream is ORIN_PLATFORM_STDOUT or ORIN_PLATFORM_STDERR && (n == 0 || p[0..n-1] readable);
    ensures all n bytes were handed to the stream (stdout: into its buffer; stderr: stdout is flushed
            first and stderr is flushed afterwards); write errors are ignored;
    assigns \stdout, \stderr; */
void orin_platform_write(int stream, const char *p, size_t n);

/*@ requires same as orin_platform_write;
    ensures as orin_platform_write(stream, p, n) followed by the single byte '\n';
    assigns \stdout, \stderr; */
void orin_platform_write_line(int stream, const char *p, size_t n);

/*@ ensures all buffered stdout bytes are delivered to fd 1;
    assigns \stdout; */
void orin_platform_flush(void);

/*@ requires n == 0 || \valid(buf + (0..n-1));
    ensures 0 <= \result <= n; buf[0..\result-1] holds the next \result bytes of stdin;
    ensures \result < n ==> end of input (or a read error) was reached; otherwise no more than
            n bytes were consumed;
    assigns buf[0..n-1], \stdin; */
size_t orin_platform_stdin_read(char *buf, size_t n);

/*@ ensures \result == -1 (end of input / error) or the next byte of stdin as 0..255;
    assigns \stdin; */
int orin_platform_stdin_getc(void);

/* ================================================================ files */

/*@ ensures \result is a NUL-terminated English description (never NULL) of the code, valid until the
            next call to this function; code 0 maps to "Success";
    assigns \nothing; */
const char *orin_platform_error_message(int code);

/*@ requires (plen == 0 || path[0..plen-1] readable) && \valid(out) && \valid(out_len);
    ensures path contains a NUL byte ==> \result == ORIN_PLATFORM_EINVAL and nothing is opened;
    ensures \result == 0 ==> *out is a block from orin_platform_alloc of capacity >= max(*out_len,1)
            holding the whole file contents; the caller frees it with orin_platform_free;
    ensures \result != 0 ==> *out == NULL, *out_len == 0 (nothing to free), \result is an errno-style
            code (ORIN_PLATFORM_ENOMEM when memory ran out, ENOENT/EACCES/EISDIR/... otherwise);
    assigns *out, *out_len, \fs (access times only); */
int orin_platform_file_read(const char *path, size_t plen, char **out, size_t *out_len);

/*@ requires (plen == 0 || path[0..plen-1] readable) && (dlen == 0 || data[0..dlen-1] readable);
    ensures path contains a NUL byte ==> \result == ORIN_PLATFORM_EINVAL and the file system is untouched;
    ensures \result == 0 ==> the file was created or truncated and now holds exactly data[0..dlen-1]
            and was closed successfully;
    ensures \result != 0 ==> errno-style code; the file may exist with partial contents;
    assigns \fs; */
int orin_platform_file_write(const char *path, size_t plen, const char *data, size_t dlen);

/*@ requires plen == 0 || path[0..plen-1] readable;
    ensures \result == 1 <==> path has no NUL byte and stat(2) on it succeeds; otherwise 0;
    assigns \nothing; */
int orin_platform_file_exists(const char *path, size_t plen);
/*@ requires plen == 0 || path[0..plen-1] readable;
    requires each is a valid callback and ctx is valid for every callback invocation;
    ensures path contains a NUL byte ==> \result == ORIN_PLATFORM_EINVAL and each is never called;
    ensures \result == 0 ==> each was called once per observed entry except "." and "..", in readdir order;
    ensures is_dir passed to each is true only for physical directories (symbolic links are not followed);
    ensures name passed to each is readable for len bytes and valid only until the callback returns;
    ensures \result != 0 ==> errno-style open, allocation, enumeration, classification or close error;
    ensures an error may follow callbacks for a partial listing; the caller must discard those entries;
    assigns \fs (access times only), callback-owned state at ctx; */
int orin_platform_dir_list(const char *path, size_t plen, void (*each)(void *ctx, const char *name, size_t len, int is_dir),
                           void *ctx);

/*@ requires (flen == 0 || from[0..flen-1] readable) && (tlen == 0 || to[0..tlen-1] readable);
    ensures either path contains a NUL byte ==> \result == ORIN_PLATFORM_EINVAL and the file system is untouched;
    ensures \result == 0 ==> rename(2): `to` now names what `from` named and `from` no longer exists; an existing `to` (a file,
            or an empty directory when `from` is a directory) was replaced atomically, no reader sees neither or both;
            symbolic links are not followed (a link is renamed, not its target);
    ensures \result != 0 ==> errno-style code (ENOENT, EACCES, EISDIR, ENOTDIR, ENOTEMPTY, EXDEV, ...), nothing changed;
    assigns \fs; */
int orin_platform_file_rename(const char *from, size_t flen, const char *to, size_t tlen);

/*@ requires plen == 0 || path[0..plen-1] readable;
    ensures path contains a NUL byte ==> \result == ORIN_PLATFORM_EINVAL and the file system is untouched;
    ensures \result == 0 ==> unlink(2): the name `path` (a file or a symbolic link, not its target) was removed;
    ensures \result != 0 ==> errno-style code (ENOENT, EACCES, EPERM or EISDIR for a directory, ...), nothing changed;
    assigns \fs; */
int orin_platform_file_remove(const char *path, size_t plen);

/*@ requires plen == 0 || path[0..plen-1] readable;
    ensures path contains a NUL byte ==> \result == ORIN_PLATFORM_EINVAL and the file system is untouched;
    ensures \result == 0 ==> rmdir(2): the empty directory `path` was removed;
    ensures \result != 0 ==> errno-style code (ENOENT, ENOTDIR, ENOTEMPTY, EACCES, EBUSY, ...), nothing changed;
    assigns \fs; */
int orin_platform_dir_remove(const char *path, size_t plen);

/*@ requires (plen == 0 || path[0..plen-1] readable) && (dlen == 0 || data[0..dlen-1] readable);
    ensures path contains a NUL byte ==> \result == ORIN_PLATFORM_EINVAL and the file system is untouched;
    ensures \result == 0 ==> a temporary file "<path>.orin-tmp-<pid>-<n>" in the directory of `path` was created exclusively,
            written with exactly data[0..dlen-1], fsync'ed, closed and renamed over `path`, then the directory was fsync'ed
            (best effort); `path` holds either its old contents or all of `data`, never a mix, even across a crash;
            a symbolic link at `path` is replaced, not followed; the new file has mode 0666 & ~umask;
    ensures \result != 0 ==> errno-style code (ENOENT for a missing directory, EACCES, ENOSPC, ...); `path` is untouched and the
            temporary file was removed (a crash can leave it behind);
    assigns \fs; */
int orin_platform_file_write_atomic(const char *path, size_t plen, const char *data, size_t dlen);

/* ---------------------------------------------------------------- file streams (ADR-0025)
 * An open file for incremental reading and writing (the substrate of the resource handle `File` of
 * std:fs). `orin_platform_stream` is an opaque OS handle owned by the caller between open and close
 * (it is the one object type of this layer; the runtime keeps the table of open streams). A stream
 * records the FIRST error of any operation on it (sticky): later operations still run, the code is
 * reported by orin_platform_stream_error and, finally, by orin_platform_stream_close. Streams are
 * block-buffered by the platform; close (and flush) deliver the buffered bytes to the OS. */
typedef struct orin_platform_stream orin_platform_stream;
#define ORIN_PLATFORM_STREAM_READ 0   /* existing file, reading only */
#define ORIN_PLATFORM_STREAM_WRITE 1  /* create or truncate, writing only */
#define ORIN_PLATFORM_STREAM_APPEND 2 /* create if missing, every write goes to the end */

/*@ requires (plen == 0 || path[0..plen-1] readable) && \valid(out);
    ensures path contains a NUL byte || mode not in {READ, WRITE, APPEND} ==> \result == ORIN_PLATFORM_EINVAL
            and nothing is opened;
    ensures \result == 0 ==> *out is a fresh open stream (opened with the given mode) that the caller must
            pass to orin_platform_stream_close exactly once;
    ensures \result != 0 ==> *out == NULL, \result is an errno-style code (ENOMEM, ENOENT, EACCES, EISDIR,
            EMFILE, ...), nothing needs to be closed;
    assigns *out, \fs; */
int orin_platform_stream_open(const char *path, size_t plen, int mode, orin_platform_stream **out);

/*@ requires s is open && (n == 0 || \valid(buf + (0..n-1)));
    ensures 0 <= \result <= n; buf[0..\result-1] holds the next \result bytes of the stream;
    ensures \result < n ==> end of file or an error (then orin_platform_stream_error(s) != 0);
    assigns buf[0..n-1], *s; */
size_t orin_platform_stream_read(orin_platform_stream *s, char *buf, size_t n);

/*@ requires s is open;
    ensures \result == -1 (end of file or error) or the next byte of the stream as 0..255;
    assigns *s; */
int orin_platform_stream_getc(orin_platform_stream *s);

/*@ requires s is open && (n == 0 || p[0..n-1] readable);
    ensures 0 <= \result <= n; \result < n ==> an error occurred (orin_platform_stream_error(s) != 0);
    ensures the \result bytes were handed to the stream's buffer (not necessarily to the OS yet);
    assigns *s, \fs; */
size_t orin_platform_stream_write(orin_platform_stream *s, const char *p, size_t n);

/*@ requires s is open;
    ensures the buffered bytes were handed to the OS; \result == orin_platform_stream_error(s) afterwards
            (0 = no operation has failed so far; a failing flush sets the sticky error);
    assigns *s, \fs; */
int orin_platform_stream_flush(orin_platform_stream *s);

/*@ requires s is open;
    ensures \result == 0 if no operation on s has failed so far, else the errno-style code of the first failure;
    assigns \nothing; */
int orin_platform_stream_error(const orin_platform_stream *s);

/*@ requires s is open;
    ensures the buffered bytes were delivered to the OS and the file is closed; \result == 0 if neither an
            earlier operation nor the final flush/close failed, else the code of the first failure;
    ensures s is dead afterwards (it must not be used or closed again);
    assigns *s, \fs; */
int orin_platform_stream_close(orin_platform_stream *s);

/* ---------------------------------------------------------------- host policy and path scopes (ADR-0021 Stage A, ADR-0027)
 * The pure/OS primitives behind the capability grants of the runtime (runtime/core/orin_runtime.c keeps the table
 * of grants; this layer only parses the host policy and decides path questions). Families are bits:
 * ORIN_PLATFORM_FAM_*. A path scope is a NORMALISED ABSOLUTE path (starts with '/', no "." or ".." component,
 * no repeated or trailing '/', except the root "/"); a path is inside a scope when it equals it or continues it
 * at a component boundary ("/a/b" contains "/a/b/c" but not "/a/bc"). */
#define ORIN_PLATFORM_FAM_FS 1u
#define ORIN_PLATFORM_FAM_PROCESS 2u
#define ORIN_PLATFORM_FAM_STDIO 4u
#define ORIN_PLATFORM_FAM_CLOCK 8u
#define ORIN_PLATFORM_FAM_NET 16u /* reserved for std:net (no operation uses it yet) */

/*@ requires n == 0 || spec[0..n-1] readable; requires \valid(mask);
    ensures \result == 0 ==> *mask is the OR of the families named in spec: a comma-separated list of the exact
            names "fs", "process", "stdio", "clock", "net", "all" (= every family); the empty text names none;
    ensures \result == ORIN_PLATFORM_EINVAL ==> spec has an unknown name, an empty element, a space or a NUL
            (the policy is rejected as a whole) and *mask == 0;
    assigns *mask; */
int orin_platform_policy_parse(const char *spec, size_t n, unsigned *mask);

/*@ requires \valid(mask);
    ensures \result == orin_platform_policy_parse(<value of the environment variable ORIN_DENY, "" if unset>, mask);
    assigns *mask; */
int orin_platform_policy_load(unsigned *mask);

/*@ requires (plen == 0 || path[0..plen-1] readable) && \valid(out + (0..cap-1));
    ensures \result == -1 (and out is untouched) if plen == 0, path[0] != '/', path has a NUL byte or
            cap < plen + 1;
    ensures \result >= 1 ==> out[0..\result-1] is the normalised absolute path denoted lexically by path ("." and
            empty components dropped, ".." removes the previous component and is dropped at the root),
            out[\result] == 0 and \result <= plen;
    assigns out[0..cap-1]; */
int64_t orin_platform_path_normalize(const char *path, size_t plen, char *out, size_t cap);

/*@ requires scope and path are normalised absolute paths of lengths slen and plen (see above);
    ensures \result == 1 <==> scope is "/" or path == scope or (path starts with scope and path[slen] == '/');
    ensures \result == 0 otherwise;
    assigns \nothing; */
int orin_platform_path_within(const char *scope, size_t slen, const char *path, size_t plen);

/*@ requires (plen == 0 || path[0..plen-1] readable) && \valid(out + (0..cap-1));
    ensures a relative path is resolved against the current directory, then as orin_platform_path_normalize;
    ensures \result == -1 on a NUL byte, an empty path, no current directory or too small a buffer, else the length;
    assigns out[0..cap-1], \fs (reads the working directory); */
int64_t orin_platform_path_absolute(const char *path, size_t plen, char *out, size_t cap);

/*@ requires abs is a normalised absolute path of length alen && \valid(out + (0..cap-1));
    ensures \result >= 1 ==> out is the canonical path: the longest existing prefix of abs with every symbolic link
            resolved, followed by the (non-existing) rest of abs unchanged; out[\result] == 0;
    ensures \result == -1 if the prefix cannot be resolved (permission, link loop, too long), if the first
            non-existing component is a dangling symbolic link, or the buffer is too small;
    assigns out[0..cap-1]; */
int64_t orin_platform_path_real(const char *abs, size_t alen, char *out, size_t cap);

/* ---------------------------------------------------------------- network (ADR-0033): blocking TCP
 * Every function takes a HANDLE: an `orin_platform_net` record owned by the caller (the runtime keeps the table and
 * the generation counter; this layer owns what a record means). A function first checks the handle (magic, kind, live,
 * not denied by ORIN_DENY=net) and, for a grant, that its scope covers what is asked, and refuses with
 * ORIN_PLATFORM_EPERM BEFORE any system call. Timeouts are mandatory: 0..ORIN_PLATFORM_NET_MAXMS, never infinite.
 * A scope is a host pattern ("*" = any, "*.sfx" = names ending in ".sfx", else the exact text, ASCII case-insensitive;
 * for listening the text is an address literal) and a port range lo..hi. Names and addresses containing '*' are invalid.
 * Results of waiting calls are one of: 0 (done), ORIN_PLATFORM_NET_EOF / _TIMEOUT / _RESET / _CANCELLED, or an errno-style code.
 * Every wait (accept, connect, recv, send) also observes the WAKE SOURCE bound to the calling thread, see below. */
#define ORIN_PLATFORM_EPERM 1
#define ORIN_PLATFORM_NET_EOF 1001 /* orderly end of the stream (recv) */
#define ORIN_PLATFORM_NET_TIMEOUT 1002
#define ORIN_PLATFORM_NET_RESET 1003 /* connection reset / aborted / broken pipe */
#define ORIN_PLATFORM_NET_CANCELLED 1004 /* the wake source bound to the thread was set (orin_platform_wake_*) */
#define ORIN_PLATFORM_NET_MAXMS 3600000
#define ORIN_PLATFORM_NET_MAGIC 0x4e455431u
enum { ORIN_PLATFORM_NET_GRANT = 1, ORIN_PLATFORM_NET_LISTENER = 2, ORIN_PLATFORM_NET_STREAM = 3 };
enum { ORIN_PLATFORM_NET_LISTEN = 1, ORIN_PLATFORM_NET_CONNECT = 2 }; /* grant.can bits; index of a scope = bit - 1 */
typedef struct {
    size_t hl;
    char h[64];
    unsigned lo, hi;
} orin_platform_scope;
typedef struct {
    unsigned magic, kind, can, deny; /* deny != 0: the host policy denies the net family */
    int fd;                           /* listener / stream: the socket, -1 once closed */
    orin_platform_scope sc[2];        /* grant: what it may listen on / connect to */
} orin_platform_net;

/*@ ensures \result == -1 on clock failure, invalid timespec or millisecond overflow;
    ensures \result >= 0 on success: monotonic milliseconds, arbitrary origin, never decreases between successful reads;
    assigns \nothing; */
int64_t orin_platform_monotonic_millis(void);

/*@ requires \valid(out) && (hl == 0 || host[0..hl-1] readable);
    ensures \result == ORIN_PLATFORM_EPERM ==> parent is not a live grant; *out untouched; no other effect;
    ensures \result == ORIN_PLATFORM_EINVAL ==> what not in {LISTEN, CONNECT}, bad host text or range; *out untouched;
    ensures \result == 0 ==> *out is a grant copied from parent with out->can == parent->can & what, and (when the parent
            may do `what` and its scope covers host:lo..hi) the `what` scope replaced by host:lo..hi, else out->can == 0:
            a narrowed grant never covers anything the parent does not;
    assigns *out; */
int orin_platform_net_narrow(const orin_platform_net *parent, unsigned what, const char *host, size_t hl, int lo, int hi,
                             orin_platform_net *out);

/*@ requires \valid(out) && \valid(out_port) && (alen == 0 || addr[0..alen-1] readable) && 1 <= backlog <= 4096;
    ensures grant not live / denied / LISTEN scope does not cover addr:port ==> \result == EPERM and no system call was made;
    ensures \result == 0 ==> *out is a LISTENER bound to addr:port (opt & 1: SO_REUSEADDR), *out_port the bound port
            (the real one when port == 0), non-blocking, close-on-exec; \result != 0 ==> *out untouched;
    assigns *out, *out_port, the network; */
int orin_platform_tcp_listen(const orin_platform_net *grant, const char *addr, size_t alen, int port, int backlog, int opt,
                             orin_platform_net *out, int *out_port);

/*@ requires \valid(out) && \valid(peer + (0..pcap-1)) && \valid(peer_port);
    ensures listener not live / denied ==> \result == EPERM, no system call;
    ensures the bound wake source (or an ancestor) is set before or during the wait ==> \result == ORIN_PLATFORM_NET_CANCELLED, no
            connection was accepted (it stays in the kernel's queue);
    ensures \result == ORIN_PLATFORM_NET_TIMEOUT ==> no connection arrived within timeout_ms;
    ensures \result == 0 ==> *out is a STREAM (opt & 1: TCP_NODELAY), peer[0..] the NUL-terminated numeric address of the
            peer (truncated to pcap - 1) and *peer_port its port; \result != 0 ==> *out untouched;
    assigns *out, peer[0..pcap-1], *peer_port, the network; */
int orin_platform_tcp_accept(const orin_platform_net *listener, int timeout_ms, int opt, orin_platform_net *out, char *peer,
                             size_t pcap, int *peer_port);

/*@ requires \valid(out) && (hl == 0 || host[0..hl-1] readable);
    ensures grant not live / denied / CONNECT scope does not cover host:port ==> \result == EPERM, no system call;
    ensures \result == 0 ==> *out is a STREAM connected to host:port within timeout_ms (opt & 1: TCP_NODELAY); a name is
            resolved by the OS resolver first (that lookup is neither bounded by timeout_ms nor interruptible); timeout_ms bounds
            the WHOLE connect, all addresses together, not each address;
    ensures the bound wake source (or an ancestor) is set before the lookup or during a wait ==> \result == NET_CANCELLED, no socket
            is left open; \result == NET_TIMEOUT or an errno-style code (ECONNREFUSED, ...) otherwise, *out untouched;
    assigns *out, the network; */
int orin_platform_tcp_connect(const orin_platform_net *grant, const char *host, size_t hl, int port, int timeout_ms, int opt,
                              orin_platform_net *out);

/*@ requires \valid(out_len) && (cap == 0 || \valid(buf + (0..cap-1)));
    ensures stream not live / denied ==> \result == EPERM, no system call; cap == 0 ==> EINVAL;
    ensures the bound wake source (or an ancestor) is set before or during the wait ==> \result == NET_CANCELLED, *out_len == 0, no
            byte was read (the kernel keeps them);
    ensures \result == 0 ==> 1 <= *out_len <= cap and buf[0..*out_len-1] holds the next bytes; \result in {NET_EOF, NET_TIMEOUT,
            NET_RESET} or an errno-style code ==> *out_len == 0; nothing outside buf[0..cap-1] is written;
    assigns buf[0..cap-1], *out_len, the network; */
int orin_platform_stream_recv(const orin_platform_net *s, char *buf, size_t cap, int timeout_ms, size_t *out_len);

/*@ requires \valid(out_sent) && (len == 0 || data[0..len-1] readable);
    ensures stream not live / denied ==> \result == EPERM, no system call;
    ensures the bound wake source (or an ancestor) is set before or during the wait ==> \result == NET_CANCELLED, *out_sent == 0;
    ensures \result == 0 ==> 0 <= *out_sent <= len bytes were handed to the OS (a partial write is normal; the caller
            sends the tail again); \result == NET_TIMEOUT ==> the socket stayed unwritable for timeout_ms (*out_sent == 0);
            \result == NET_RESET ==> the peer is gone (no SIGPIPE is raised);
    assigns *out_sent, the network; */
int orin_platform_stream_send(const orin_platform_net *s, const char *data, size_t len, int timeout_ms, size_t *out_sent);

/*@ ensures stream not live / denied ==> \result == EPERM; how not in {0 read, 1 write, 2 both} ==> EINVAL;
    ensures \result == 0 ==> that direction is shut down (how 1 sends FIN: the half-close of a graceful close);
    assigns the network; */
int orin_platform_net_shutdown(const orin_platform_net *s, int how);

/*@ ensures h not an initialised record ==> \result == EPERM; otherwise \result == 0 and the socket (if any) is closed,
            h->fd == -1 and h->can == 0: closing twice is harmless;
    assigns *h, the network; */
int orin_platform_net_close(orin_platform_net *h);

/*@ requires \valid(out + (0..cap-1)) && \valid(out_len) && (nlen == 0 || name[0..nlen-1] readable);
    ensures grant not live / denied / CONNECT scope does not cover name (any port) ==> EPERM, no system call;
    ensures the bound wake source is set before the lookup ==> NET_CANCELLED; once started, getaddrinfo is NOT interruptible: it runs
            to the OS resolver's own end (the one blocking call of this layer that no wake source or timeout reaches);
    ensures \result == 0 ==> out[0..*out_len-1] holds the numeric addresses of name, each followed by '\n' (IPv4 and IPv6,
            duplicates removed, as many as fit), *out_len <= cap; \result == ENOENT when the name does not resolve;
    assigns out[0..cap-1], *out_len, the network (DNS); */
int orin_platform_dns_resolve(const orin_platform_net *grant, const char *name, size_t nlen, char *out, size_t cap, size_t *out_len);

/* ---------------------------------------------------------------- wake sources (ADR-0017 Addendum D)
 * A wake source is a cancellation token that blocked network waits observe. It is a record of this layer with a flag and a
 * descriptor (eventfd, a pipe off Linux) that is created the first time a wait polls it. A thread BINDS one source; the waits of
 * orin_platform_tcp_accept / _connect / _stream_recv / _stream_send poll it together with their socket and return
 * ORIN_PLATFORM_NET_CANCELLED when it is set, also when it was set before the call (checked first, so a cancelled task never
 * starts new network work). Sources form a tree: a source opened while another is bound is its child, and a wait observes the
 * child and every ancestor (at most ORIN_PLATFORM_WAKE_DEPTH + 1 levels). A source stays set (cancellation is permanent).
 * Handles are `generation << 32 | (index + 1)`: a closed source's handle never names a later source that reuses its slot
 * (the generation changes on close), so a token kept after its scope ended can neither signal nor be mistaken for another.
 * Thread safe: one internal lock; a source must be closed only when no thread still waits on it (std:task closes it after
 * every task of its scope has ended). */
#define ORIN_PLATFORM_WAKE_DEPTH 32

/*@ ensures \result == 0 ==> no source was made (the table is full, or the bound source already has WAKE_DEPTH ancestors); nothing bound;
    ensures \result > 0 ==> \result names a fresh live, unset source whose parent is the source bound before the call (0 = none), and
            it is now bound to the calling thread; no descriptor is made yet;
    assigns the table, the calling thread's binding; */
int64_t orin_platform_wake_open(void);

/*@ ensures h is not a live handle (never opened, forged, closed already, or from an earlier generation) ==> \result == ORIN_PLATFORM_EINVAL,
            nothing happens;
    ensures \result == 0 ==> the source is gone, its descriptor closed, its slot reusable under a new generation; when it was bound
            to the calling thread, the thread is bound to its parent again;
    assigns the table, the calling thread's binding; */
int64_t orin_platform_wake_close(int64_t h);

/*@ ensures \result == 1 ==> h was live and unset and is set now: every wait observing it or a descendant, now or later, returns
            NET_CANCELLED;
    ensures \result == 0 ==> nothing changed (h is stale or forged, or the source was already set); signalling is idempotent;
    assigns the source's flag and descriptor; */
int64_t orin_platform_wake_signal(int64_t h);

/*@ ensures \result == 2 ==> h is not a live handle; \result == 1 ==> h or an ancestor is set; \result == 0 ==> neither; assigns \nothing; */
int64_t orin_platform_wake_check(int64_t h);

/*@ ensures \result == the handle bound to the calling thread before the call (0 = none); the thread is bound to h (0 unbinds). A
            handle that is not live binds as "nothing" (waits ignore it); a new thread starts unbound;
    assigns the calling thread's binding; */
int64_t orin_platform_wake_bind(int64_t h);

/*@ ensures \result == the handle bound to the calling thread (0 = none); assigns \nothing; */
int64_t orin_platform_wake_bound(void);

#ifdef __cplusplus
}
#endif
#endif
