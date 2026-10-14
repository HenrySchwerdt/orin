// Java counterpart (tools/bench.py runs it with `java -XX:+UseParallelGC`; an optional argument N repeats the work N times
// in one JVM and reports the milliseconds of every repetition on stderr, to separate cold start from warmed-up time).
public class Main {
    static long fib(long n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

    static String work() { return "fib(40)=" + fib(40) + "\n"; }

    public static void main(String[] a) {
        int reps = a.length > 0 ? Integer.parseInt(a[0]) : 1;
        for (int r = 0; r < reps; r++) {
            long t = System.nanoTime();
            String out = work();
            if (r == 0) System.out.print(out);
            if (reps > 1) System.err.println("rep " + r + " " + (System.nanoTime() - t) / 1000000 + " ms");
        }
    }
}
