package android.graphics;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** An outline as straight segments: curves are cut into short lines as they are added (see Canvas). */
public class Path {
    private static final int CURVE_STEPS = 16;
    private final List<float[]> done = new ArrayList<>();
    private float[] points = new float[32];
    private int count;
    private float x, y, startX, startY;

    public Path() { }
    public Path(Path other) { done.addAll(other.contours()); x = other.x; y = other.y; startX = other.startX; startY = other.startY; }

    public void reset() { done.clear(); count = 0; x = y = startX = startY = 0; }
    public void rewind() { reset(); }
    public boolean isEmpty() { return done.isEmpty() && count == 0; }
    public void moveTo(float x, float y) { finish(); this.x = startX = x; this.y = startY = y; add(x, y); }
    public void lineTo(float x, float y) { begin(); add(x, y); this.x = x; this.y = y; }
    public void quadTo(float x1, float y1, float x2, float y2) {
        begin();
        float x0 = x, y0 = y;
        for (int step = 1; step <= CURVE_STEPS; step++) {
            float t = step / (float) CURVE_STEPS, u = 1 - t;
            add(u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2);
        }
        x = x2; y = y2;
    }
    public void cubicTo(float x1, float y1, float x2, float y2, float x3, float y3) {
        begin();
        float x0 = x, y0 = y;
        for (int step = 1; step <= CURVE_STEPS; step++) {
            float t = step / (float) CURVE_STEPS, u = 1 - t;
            float a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
            add(a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3);
        }
        x = x3; y = y3;
    }
    public void close() {
        if (count > 0) { add(startX, startY); x = startX; y = startY; }
        finish();
    }

    /** Every contour so far, each as x, y pairs. */
    List<float[]> contours() {
        List<float[]> all = new ArrayList<>(done);
        if (count > 0) all.add(Arrays.copyOf(points, count * 2));
        return all;
    }
    private void begin() { if (count == 0) { startX = x; startY = y; add(x, y); } }
    private void add(float x, float y) {
        if (count * 2 + 2 > points.length) points = Arrays.copyOf(points, points.length * 2);
        points[count * 2] = x; points[count * 2 + 1] = y; count++;
    }
    private void finish() {
        if (count > 0) done.add(Arrays.copyOf(points, count * 2));
        count = 0;
    }
}
