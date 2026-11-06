package android.animation;

public class ArgbEvaluator implements TypeEvaluator<Object> {
    private static final ArgbEvaluator INSTANCE = new ArgbEvaluator();
    public static ArgbEvaluator getInstance() { return INSTANCE; }
    @Override public Object evaluate(float fraction, Object start, Object end) {
        int from = (Integer) start, to = (Integer) end, mixed = 0;
        for (int shift = 0; shift <= 24; shift += 8) { int a = (from >>> shift) & 255, b = (to >>> shift) & 255; mixed |= Math.round(a + (b - a) * fraction) << shift; }
        return mixed;
    }
}
