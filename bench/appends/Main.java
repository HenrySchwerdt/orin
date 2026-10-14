// Java counterpart, see bench/fib/Main.java (StringBuilder / growable long array: Java's `s += t` is quadratic too).
public class Main {
    static final class Rec { StringBuilder s = new StringBuilder(); long[] a = new long[4]; int n = 0;
        void push(long v) { if (n == a.length) a = java.util.Arrays.copyOf(a, n * 2); a[n++] = v; } }

    static final class Buf { StringBuilder s = new StringBuilder(); void add(String t) { s.append(t); } }

    static String work() {
        StringBuilder out = new StringBuilder();
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < 200000; i++) s.append('x');
        out.append("local ").append(s.length()).append('\n');
        Rec r = new Rec();
        for (int i = 0; i < 200000; i++) r.s.append('y');
        out.append("field ").append(r.s.length()).append('\n');
        Buf b = new Buf();
        for (int i = 0; i < 200000; i++) b.add("z");
        out.append("class field ").append(b.s.length()).append('\n');
        Rec[] rs = { new Rec(), new Rec() };
        for (int i = 0; i < 200000; i++) rs[1].s.append('w');
        out.append("element ").append(rs[1].s.length()).append(' ').append(rs[0].s.length()).append('\n');
        Rec ar = new Rec();
        for (long i = 0; i < 100000; i++) ar.push(i);
        out.append("array ").append(ar.n).append(' ').append(ar.a[99999]).append('\n');
        for (long i = 0; i < 100000; i++) { r.push(i); r.push(i); }
        out.append("array field ").append(r.n).append(' ').append(r.a[199999]).append('\n');
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
