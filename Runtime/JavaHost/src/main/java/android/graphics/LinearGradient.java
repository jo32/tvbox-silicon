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
        this.x0 = x0; this.y0 = y0; dx = x1 - x0; dy = y1 - y0; length = dx * dx + dy * dy;
        this.positions = stops(colors, positions);
        this.colors = colors.clone();
        this.tile = tile;
    }

    @Override int colorAt(float x, float y) {
        return mix(colors, positions, tile, length == 0 ? 0 : ((x - x0) * dx + (y - y0) * dy) / length);
    }
}
