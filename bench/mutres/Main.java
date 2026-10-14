// Java counterpart, see bench/fib/Main.java.
public class Main {
    static final class Reader {
        final long[] data; int pos = 0;
        Reader(long[] d) { data = d; }
        long next() { long v = data[pos]; pos++; if (pos == data.length) pos = 0; return v; }
        void skip() { pos++; if (pos == data.length) pos = 0; }
        long cur() { return data[pos]; }
    }

    static final class Q {
        final Reader r; long total = 0;
        Q(long[] d) { r = new Reader(d); }
        long stepRet() { long v = r.next(); total += v; return v; }
        void stepVoid() { total += r.cur(); r.skip(); }
    }

    static String work() {
        long[] d = new long[16];
        for (int i = 0; i < 16; i++) d[i] = i + 1;
        Q q = new Q(d);
        Reader r = new Reader(d);
        long sum = 0;
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 10000000; i++) sum += r.next();
        out.append("ret ").append(sum).append(' ').append(r.pos).append('\n');
        for (int i = 0; i < 10000000; i++) { r.skip(); sum += r.cur(); }
        out.append("void ").append(sum).append(' ').append(r.pos).append('\n');
        for (int i = 0; i < 10000000; i++) sum += q.stepRet();
        out.append("nested ret ").append(sum).append(' ').append(q.total).append('\n');
        for (int i = 0; i < 10000000; i++) q.stepVoid();
        out.append("nested void ").append(q.total).append(' ').append(q.r.pos).append('\n');
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
