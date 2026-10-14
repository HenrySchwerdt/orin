// Java counterpart, see bench/fib/Main.java: byte[] <-> String of 1 MiB (ISO-8859-1: one byte per character).
import java.nio.charset.StandardCharsets;

public class Main {
    static String work() {
        String s = "0123456789abcdef".repeat(65536);
        long total = 0;
        for (int round = 0; round < 40; round++) {
            byte[] b = s.getBytes(StandardCharsets.ISO_8859_1);
            String t = new String(b, StandardCharsets.ISO_8859_1);
            total += t.length() + t.charAt(round * 7919) + (b[round] & 0xff);
        }
        return "len " + s.length() + "\ntotal " + total + "\n";
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
