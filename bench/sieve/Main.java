// Java counterpart, see bench/fib/Main.java. long[] flags like the other languages (8-byte flags).
public class Main {
    static String work() {
        int n = 10000000;
        long[] flags = new long[n + 1];
        java.util.Arrays.fill(flags, 1);
        flags[0] = 0;
        flags[1] = 0;
        for (int i = 2; (long) i * i <= n; i++) {
            if (flags[i] == 1) {
                for (int j = i * i; j <= n; j += i) flags[j] = 0;
            }
        }
        long count = 0;
        for (int i = 0; i <= n; i++) count += flags[i];
        return "primes<=10000000: " + count + "\n";
    }

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
