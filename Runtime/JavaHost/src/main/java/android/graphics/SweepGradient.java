package android.graphics;

/** Colors around the center (cx, cy), clockwise from 3 o'clock, as a color wheel's hue ring. */
public class SweepGradient extends Shader {
    private final float cx, cy;
    private final int[] colors;
    private final float[] positions;

    public SweepGradient(float cx, float cy, int color0, int color1) { this(cx, cy, new int[]{color0, color1}, null); }
    public SweepGradient(float cx, float cy, int[] colors, float[] positions) {
        this.cx = cx; this.cy = cy;
        this.positions = stops(colors, positions);
        this.colors = colors.clone();
    }

    @Override int colorAt(float x, float y) {
        double degrees = Math.toDegrees(Math.atan2(y - cy, x - cx));
        if (degrees < 0) degrees += 360;
        return mix(colors, positions, TileMode.CLAMP, (float) (degrees / 360));
    }
}
