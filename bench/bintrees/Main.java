// Java counterpart, see bench/fib/Main.java. A null child plays the role of Orin's `Leaf` variant.
public class Main {
    static final class Node { final Node l, r; Node(Node l, Node r) { this.l = l; this.r = r; } }

    static Node build(long d) { return d == 0 ? new Node(null, null) : new Node(build(d - 1), build(d - 1)); }

    static long check(Node t) { return t == null ? 0 : 1 + check(t.l) + check(t.r); }

    static String work() {
        StringBuilder out = new StringBuilder();
        long maxDepth = 16;
        Node longLived = build(maxDepth);
        long total = 0;
        for (long d = 4; d <= maxDepth; d += 4) {
            long iters = 1L << (22 - d);
            long sum = 0;
            for (long i = 0; i < iters; i++) sum += check(build(d));
            out.append("depth ").append(d).append(" trees ").append(iters).append(" check ").append(sum).append('\n');
            total += sum;
        }
        out.append("long lived check ").append(check(longLived)).append('\n');
        out.append("total ").append(total).append('\n');
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
