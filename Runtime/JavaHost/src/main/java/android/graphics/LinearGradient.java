package android.graphics;

/** Colors along the line from (x0, y0) to (x1, y1), spread evenly unless positions are given. */
public class LinearGradient extends Shader {
    private final float x0, y0, dx, dy, length;
    private final int[] colors;
    private final float[] positions;
    private final TileMode tile;

    public LinearGradient(float x0, float y0, float x1, float y1, int color0, int color1, TileMode tile) {
        this(x0, y0, x1, y1, new int[]{color0, color1}, null, tile);
    }
    public LinearGradient(float x0, float y0, float x1, float y1, int[] colors, float[] positions, TileMode tile) {
        if (colors == null || colors.length < 2) throw new IllegalArgumentException("needs >= 2 number of colors");
        this.x0 = x0; this.y0 = y0; dx = x1 - x0; dy = y1 - y0; length = dx * dx + dy * dy;
        this.colors = colors.clone();
        float[] at = new float[colors.length];
        for (int i = 0; i < at.length; i++) at[i] = positions != null && positions.length == colors.length ? positions[i] : i / (float) (at.length - 1);
        this.positions = at;
        this.tile = tile == null ? TileMode.CLAMP : tile;
    }

    int colorAt(float x, float y) {
        float t = length == 0 ? 0 : ((x - x0) * dx + (y - y0) * dy) / length;
        switch (tile) {
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
