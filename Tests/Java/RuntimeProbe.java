package tvbox;
/** A controlled DEX fixture, not a claim of CatVod compatibility. */
public final class RuntimeProbe {
    public static int run() {
        int sum = 0;
        for (int i = 0; i < 7; i++) sum += i;
        return twice(sum);
    }
    private static int twice(int value) { return value * 2; }
    public static int forever() { int n = 0; while (true) { n++; } }
}
