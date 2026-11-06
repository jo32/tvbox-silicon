package android.view.animation;

public class AccelerateInterpolator implements Interpolator {
    private final float factor;
    public AccelerateInterpolator() { this(1f); }
    public AccelerateInterpolator(float factor) { this.factor = factor; }
    @Override public float getInterpolation(float input) { return factor == 1f ? input * input : (float) Math.pow(input, 2 * factor); }
}
