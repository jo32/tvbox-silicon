package android.view.animation;

public class DecelerateInterpolator implements Interpolator {
    private final float factor;
    public DecelerateInterpolator() { this(1f); }
    public DecelerateInterpolator(float factor) { this.factor = factor; }
    @Override public float getInterpolation(float input) { return factor == 1f ? 1f - (1f - input) * (1f - input) : (float) (1f - Math.pow(1f - input, 2 * factor)); }
}
