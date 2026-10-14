// Java counterpart, see bench/fib/Main.java.
import java.util.ArrayList;

public class Main {
    static String work() {
        StringBuilder b = new StringBuilder();
        for (long i = 0; i < 500000; i++) b.append("item").append(i).append(',');
        String s = b.toString();
        // split(",") keeping the trailing empty part, like Go and Orin
        ArrayList<String> parts = new ArrayList<>();
        int start = 0;
        for (int i = 0; i < s.length(); i++) {
            if (s.charAt(i) == ',') { parts.add(s.substring(start, i)); start = i + 1; }
        }
        parts.add(s.substring(start));
        String joined = String.join(";", parts);
        long sum = 0, nonEmpty = 0;
        for (String p : parts) {
            if (p.length() > 0) { sum += Long.parseLong(p.substring(4)); nonEmpty++; }
        }
        return "len " + s.length() + "\nparts " + parts.size() + " nonEmpty " + nonEmpty + "\njoined " + joined.length() + "\nsum " + sum + "\n";
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
