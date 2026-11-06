package android.graphics;

/** What Paint fills with instead of its color: subclasses give the color at each pixel. */
public class Shader {
    public enum TileMode { CLAMP, REPEAT, MIRROR, DECAL }

    /** Transparent outside what the subclass covers. */
    int colorAt(float x, float y) { return 0; }

    /** Color stops spread evenly unless the plugin gives positions. */
    static float[] stops(int[] colors, float[] positions) {
        if (colors == null || colors.length < 2) throw new IllegalArgumentException("needs >= 2 number of colors");
        float[] at = new float[colors.length];
        for (int i = 0; i < at.length; i++) at[i] = positions != null && positions.length == colors.length ? positions[i] : i / (float) (at.length - 1);
        return at;
    }

    /** The color at `t` along the stops after tiling, or 0 for DECAL outside [0, 1]. */
    static int mix(int[] colors, float[] positions, TileMode tile, float t) {
        switch (tile == null ? TileMode.CLAMP : tile) {
            case REPEAT -> t = t - (float) Math.floor(t);
            case MIRROR -> { t = Math.abs(t) % 2; if (t > 1) t = 2 - t; }
            case DECAL -> { if (t < 0 || t > 1) return 0; }
            default -> t = Math.max(0, Math.min(1, t));
        }
        if (t <= positions[0]) return colors[0];
        for (int i = 1; i < colors.length; i++) {
            if (t > positions[i]) continue;
            float span = positions[i] - positions[i - 1], f = span <= 0 ? 1 : (t - positions[i - 1]) / span;
            int from = colors[i - 1], to = colors[i], mixed = 0;
            for (int shift = 0; shift <= 24; shift += 8) {
                int a = (from >>> shift) & 255, b = (to >>> shift) & 255;
                mixed |= Math.round(a + (b - a) * f) << shift;
            }
            return mixed;
        }
        return colors[colors.length - 1];
    }
}
