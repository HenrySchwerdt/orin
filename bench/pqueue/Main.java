// Java counterpart, see bench/fib/Main.java: java.util.PriorityQueue of (priority, value) pairs.
import java.util.PriorityQueue;

public class Main {
    static long nextRand(long s) { return (s * 1103515245L + 12345) % 2147483648L; }

    static String work() {
        PriorityQueue<long[]> q = new PriorityQueue<>((x, y) -> Long.compare(x[0], y[0]));
        StringBuilder out = new StringBuilder();
        long seed = 1;
        for (long i = 0; i < 200000; i++) { seed = nextRand(seed); q.add(new long[] { seed % 1000003, i }); }
        out.append("size ").append(q.size()).append('\n');
        long check = 0;
        for (long i = 0; i < 400000; i++) {
            seed = nextRand(seed);
            q.add(new long[] { seed % 1000003, i });
            long p = q.poll()[0];
            check = (check * 31 + p) % 1000000007L;
        }
        out.append("interleaved ").append(check).append(" size ").append(q.size()).append('\n');
        long n = 0, sum = 0, last = -1;
        boolean ordered = true;
        while (!q.isEmpty()) {
            long p = q.poll()[0];
            if (p < last) ordered = false;
            last = p; n++;
            sum = (sum + p * (n % 1000)) % 1000000007L;
        }
        out.append("drained ").append(n).append(" ordered ").append(ordered).append(" sum ").append(sum).append('\n');
        return out.toString();
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
