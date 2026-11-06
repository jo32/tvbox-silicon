package android.graphics;

/** Colors from the center (cx, cy) out to `radius`. */
public class RadialGradient extends Shader {
    private final float cx, cy, radius;
    private final int[] colors;
    private final float[] positions;
    private final TileMode tile;

    public RadialGradient(float centerX, float centerY, float radius, int centerColor, int edgeColor, TileMode tile) {
        this(centerX, centerY, radius, new int[]{centerColor, edgeColor}, null, tile);
    }
    public RadialGradient(float centerX, float centerY, float radius, int[] colors, float[] stops, TileMode tile) {
        if (radius <= 0) throw new IllegalArgumentException("radius must be > 0");
        cx = centerX; cy = centerY; this.radius = radius;
        positions = stops(colors, stops);
        this.colors = colors.clone();
        this.tile = tile;
    }

    @Override int colorAt(float x, float y) {
        return mix(colors, positions, tile, (float) Math.hypot(x - cx, y - cy) / radius);
    }
}
