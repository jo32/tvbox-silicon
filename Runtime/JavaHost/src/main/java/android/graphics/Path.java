package android.graphics;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** An outline as straight segments: curves are cut into short lines as they are added (see Canvas). */
public class Path {
    public enum FillType { WINDING, EVEN_ODD, INVERSE_WINDING, INVERSE_EVEN_ODD }
    public enum Direction { CW, CCW }
    private static final int CURVE_STEPS = 16;
    private final List<float[]> done = new ArrayList<>();
    private float[] points = new float[32];
    private int count;
    private float x, y, startX, startY;
    private FillType fillType = FillType.WINDING;

    public Path() { }
    public Path(Path other) { done.addAll(other.contours()); x = other.x; y = other.y; startX = other.startX; startY = other.startY; fillType = other.fillType; }

    public void reset() { done.clear(); count = 0; x = y = startX = startY = 0; fillType = FillType.WINDING; }
    public void rewind() { done.clear(); count = 0; x = y = startX = startY = 0; }
    public void set(Path other) { if (other != this) { reset(); done.addAll(other.contours()); x = other.x; y = other.y; fillType = other.fillType; } }
    public boolean isEmpty() { return done.isEmpty() && count == 0; }
    public FillType getFillType() { return fillType; }
    public void setFillType(FillType value) { fillType = value == null ? FillType.WINDING : value; }
    public boolean isInverseFillType() { return fillType == FillType.INVERSE_WINDING || fillType == FillType.INVERSE_EVEN_ODD; }
    public void toggleInverseFillType() { fillType = FillType.values()[fillType.ordinal() ^ 2]; }
    public void moveTo(float x, float y) { finish(); this.x = startX = x; this.y = startY = y; add(x, y); }
    public void rMoveTo(float dx, float dy) { moveTo(x + dx, y + dy); }
    public void lineTo(float x, float y) { begin(); add(x, y); this.x = x; this.y = y; }
    public void rLineTo(float dx, float dy) { lineTo(x + dx, y + dy); }
    public void quadTo(float x1, float y1, float x2, float y2) {
        begin();
        float x0 = x, y0 = y;
        for (int step = 1; step <= CURVE_STEPS; step++) {
            float t = step / (float) CURVE_STEPS, u = 1 - t;
            add(u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2);
        }
        x = x2; y = y2;
    }
    public void rQuadTo(float dx1, float dy1, float dx2, float dy2) { quadTo(x + dx1, y + dy1, x + dx2, y + dy2); }
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
    public void rCubicTo(float x1, float y1, float x2, float y2, float x3, float y3) { cubicTo(x + x1, y + y1, x + x2, y + y2, x + x3, y + y3); }
    public void close() {
        if (count > 0) { add(startX, startY); x = startX; y = startY; }
        finish();
    }
    public void addRect(float left, float top, float right, float bottom, Direction dir) {
        moveTo(left, top); lineTo(right, top); lineTo(right, bottom); lineTo(left, bottom); close();
    }
    public void addRect(RectF rect, Direction dir) { addRect(rect.left, rect.top, rect.right, rect.bottom, dir); }
    public void addOval(RectF oval, Direction dir) { addArcPoints(oval, 0, 360, true); }
    public void addOval(float left, float top, float right, float bottom, Direction dir) { addOval(new RectF(left, top, right, bottom), dir); }
    public void addCircle(float cx, float cy, float radius, Direction dir) { addOval(new RectF(cx - radius, cy - radius, cx + radius, cy + radius), dir); }
    public void addArc(RectF oval, float startAngle, float sweepAngle) { addArcPoints(oval, startAngle, sweepAngle, false); }
    public void arcTo(RectF oval, float startAngle, float sweepAngle) { arcTo(oval, startAngle, sweepAngle, false); }
    public void arcTo(RectF oval, float startAngle, float sweepAngle, boolean forceMoveTo) {
        float cx = oval.centerX(), cy = oval.centerY(), rx = oval.width() / 2, ry = oval.height() / 2;
        int steps = Math.max(2, (int) Math.ceil(Math.abs(sweepAngle) / 6));
        for (int step = 0; step <= steps; step++) {
            double angle = Math.toRadians(startAngle + sweepAngle * step / steps);
            float px = cx + (float) (rx * Math.cos(angle)), py = cy + (float) (ry * Math.sin(angle));
            if (step == 0 && (forceMoveTo || count == 0)) moveTo(px, py); else lineTo(px, py);
        }
    }
    public void addRoundRect(RectF rect, float rx, float ry, Direction dir) {
        rx = Math.min(Math.abs(rx), Math.abs(rect.width()) / 2); ry = Math.min(Math.abs(ry), Math.abs(rect.height()) / 2);
        finish();
        corner(rect.right - rx, rect.top + ry, rx, ry, -90, true);
        corner(rect.right - rx, rect.bottom - ry, rx, ry, 0, false);
        corner(rect.left + rx, rect.bottom - ry, rx, ry, 90, false);
        corner(rect.left + rx, rect.top + ry, rx, ry, 180, false);
        close();
    }
    public void addRoundRect(RectF rect, float[] radii, Direction dir) {
        float r = radii == null || radii.length == 0 ? 0 : radii[0];
        addRoundRect(rect, r, radii != null && radii.length > 1 ? radii[1] : r, dir);
    }
    public void addPath(Path other) { finish(); done.addAll(other.contours()); }
    public void offset(float dx, float dy) {
        finish();
        for (float[] contour : done) for (int i = 0; i + 1 < contour.length; i += 2) { contour[i] += dx; contour[i + 1] += dy; }
        x += dx; y += dy; startX += dx; startY += dy;
    }
    public void computeBounds(RectF bounds, boolean exact) {
        float l = Float.MAX_VALUE, t = Float.MAX_VALUE, r = -Float.MAX_VALUE, b = -Float.MAX_VALUE;
        for (float[] contour : contours()) for (int i = 0; i + 1 < contour.length; i += 2) {
            l = Math.min(l, contour[i]); r = Math.max(r, contour[i]); t = Math.min(t, contour[i + 1]); b = Math.max(b, contour[i + 1]);
        }
        if (l > r) bounds.set(0, 0, 0, 0); else bounds.set(l, t, r, b);
    }
    private void corner(float cx, float cy, float rx, float ry, float start, boolean first) {
        for (int step = 0; step <= 8; step++) {
            double angle = Math.toRadians(start + step * 90.0 / 8);
            float px = cx + (float) (rx * Math.cos(angle)), py = cy + (float) (ry * Math.sin(angle));
            if (first && step == 0) moveTo(px, py); else lineTo(px, py);
        }
    }
    private void addArcPoints(RectF oval, float start, float sweep, boolean closed) {
        finish();
        arcTo(oval, start, Math.max(-360, Math.min(360, sweep)), true);
        if (closed) close(); else finish();
    }

    /** Every contour so far, each as x, y pairs. */
    List<float[]> contours() {
        List<float[]> all = new ArrayList<>(done);
        if (count > 0) all.add(Arrays.copyOf(points, count * 2));
        return all;
    }
    boolean evenOdd() { return fillType == FillType.EVEN_ODD || fillType == FillType.INVERSE_EVEN_ODD; }
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
