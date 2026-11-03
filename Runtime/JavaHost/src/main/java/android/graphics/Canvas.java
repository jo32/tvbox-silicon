package android.graphics;

import java.util.ArrayList;
import java.util.List;

/**
 * Draws shapes into a Bitmap, for plugins that paint small images such as a config center's tile
 * icons (#360). Every shape becomes straight segments, filled with the nonzero rule or stroked with
 * round ends, without antialiasing. Text is not drawn: there are no fonts here.
 */
public class Canvas {
    private final Bitmap bitmap;
    public Canvas() { this(null); }
    public Canvas(Bitmap bitmap) { this.bitmap = bitmap; }

    public int getWidth() { return bitmap == null ? 0 : bitmap.getWidth(); }
    public int getHeight() { return bitmap == null ? 0 : bitmap.getHeight(); }
    public int save() { return 1; }
    public void restore() { }

    public void drawColor(int color) {
        if (bitmap == null) return;
        for (int y = 0; y < bitmap.getHeight(); y++) for (int x = 0; x < bitmap.getWidth(); x++) bitmap.blend(x, y, color);
    }
    public void drawRect(float left, float top, float right, float bottom, Paint paint) {
        draw(List.of(new float[]{left, top, right, top, right, bottom, left, bottom, left, top}), paint);
    }
    public void drawRect(RectF rect, Paint paint) { drawRect(rect.left, rect.top, rect.right, rect.bottom, paint); }
    public void drawRoundRect(RectF rect, float rx, float ry, Paint paint) {
        rx = Math.min(Math.abs(rx), Math.abs(rect.width()) / 2); ry = Math.min(Math.abs(ry), Math.abs(rect.height()) / 2);
        Path path = new Path();
        corner(path, rect.right - rx, rect.top + ry, rx, ry, -90, true);
        corner(path, rect.right - rx, rect.bottom - ry, rx, ry, 0, false);
        corner(path, rect.left + rx, rect.bottom - ry, rx, ry, 90, false);
        corner(path, rect.left + rx, rect.top + ry, rx, ry, 180, false);
        path.close();
        drawPath(path, paint);
    }
    private static void corner(Path path, float cx, float cy, float rx, float ry, float start, boolean first) {
        for (int step = 0; step <= 8; step++) {
            double angle = Math.toRadians(start + step * 90.0 / 8);
            float x = cx + (float) (rx * Math.cos(angle)), y = cy + (float) (ry * Math.sin(angle));
            if (first && step == 0) path.moveTo(x, y); else path.lineTo(x, y);
        }
    }
    public void drawCircle(float cx, float cy, float radius, Paint paint) { drawOval(new RectF(cx - radius, cy - radius, cx + radius, cy + radius), paint); }
    public void drawOval(RectF oval, Paint paint) { drawPath(arc(oval, 0, 360, false, true), paint); }
    public void drawArc(RectF oval, float startAngle, float sweepAngle, boolean useCenter, Paint paint) {
        drawPath(arc(oval, startAngle, sweepAngle, useCenter, useCenter || Math.abs(sweepAngle) >= 360), paint);
    }
    private static Path arc(RectF oval, float start, float sweep, boolean center, boolean closed) {
        Path path = new Path();
        float cx = oval.centerX(), cy = oval.centerY(), rx = oval.width() / 2, ry = oval.height() / 2;
        sweep = Math.max(-360, Math.min(360, sweep));
        if (center) path.moveTo(cx, cy);
        int steps = Math.max(4, (int) Math.ceil(Math.abs(sweep) / 6));
        for (int step = 0; step <= steps; step++) {
            double angle = Math.toRadians(start + sweep * step / steps);
            float x = cx + (float) (rx * Math.cos(angle)), y = cy + (float) (ry * Math.sin(angle));
            if (step == 0 && !center) path.moveTo(x, y); else path.lineTo(x, y);
        }
        if (closed) path.close();
        return path;
    }
    public void drawLine(float startX, float startY, float stopX, float stopY, Paint paint) {
        if (bitmap == null) return;
        boolean[] covered = new boolean[bitmap.getWidth() * bitmap.getHeight()];
        stroke(List.of(new float[]{startX, startY, stopX, stopY}), Math.max(1, paint.getStrokeWidth()), covered);
        paint(covered, paint);
    }
    public void drawPath(Path path, Paint paint) { draw(path.contours(), paint); }
    public void drawText(String text, float x, float y, Paint paint) { }

    private void draw(List<float[]> contours, Paint paint) {
        if (bitmap == null || contours.isEmpty()) return;
        boolean[] covered = new boolean[bitmap.getWidth() * bitmap.getHeight()];
        if (paint.getStyle() != Paint.Style.STROKE) fill(contours, covered);
        if (paint.getStyle() != Paint.Style.FILL) stroke(contours, Math.max(1, paint.getStrokeWidth()), covered);
        paint(covered, paint);
    }

    /** Pixels whose centres are inside the outline, by the nonzero winding rule (Android's default). */
    private void fill(List<float[]> contours, boolean[] covered) {
        int width = bitmap.getWidth(), height = bitmap.getHeight();
        List<float[]> crossings = new ArrayList<>();
        for (int y = 0; y < height; y++) {
            float sampleY = y + 0.5f;
            crossings.clear();
            for (float[] points : contours) {
                int count = points.length / 2;
                for (int i = 0; i < count; i++) {
                    float x0 = points[i * 2], y0 = points[i * 2 + 1];
                    int next = (i + 1) % count;
                    float x1 = points[next * 2], y1 = points[next * 2 + 1];
                    if ((y0 <= sampleY) == (y1 <= sampleY)) continue;
                    crossings.add(new float[]{x0 + (sampleY - y0) / (y1 - y0) * (x1 - x0), y1 > y0 ? 1 : -1});
                }
            }
            crossings.sort((a, b) -> Float.compare(a[0], b[0]));
            int winding = 0;
            for (int i = 0; i + 1 < crossings.size(); i++) {
                winding += (int) crossings.get(i)[1];
                if (winding == 0) continue;
                int from = Math.max(0, (int) Math.ceil(crossings.get(i)[0] - 0.5f));
                int to = Math.min(width - 1, (int) Math.floor(crossings.get(i + 1)[0] - 0.5f));
                for (int x = from; x <= to; x++) covered[y * width + x] = true;
            }
        }
    }

    /** Pixels within half the stroke width of a segment, which gives round ends and joins. */
    private void stroke(List<float[]> contours, float strokeWidth, boolean[] covered) {
        int width = bitmap.getWidth(), height = bitmap.getHeight();
        float half = strokeWidth / 2, limit = half * half;
        for (float[] points : contours) {
            for (int i = 0; i + 3 < points.length || (i == 0 && points.length == 2); i += 2) {
                float x0 = points[i], y0 = points[i + 1];
                float x1 = points.length == 2 ? x0 : points[i + 2], y1 = points.length == 2 ? y0 : points[i + 3];
                int left = Math.max(0, (int) Math.floor(Math.min(x0, x1) - half)), right = Math.min(width - 1, (int) Math.ceil(Math.max(x0, x1) + half));
                int top = Math.max(0, (int) Math.floor(Math.min(y0, y1) - half)), bottom = Math.min(height - 1, (int) Math.ceil(Math.max(y0, y1) + half));
                float dx = x1 - x0, dy = y1 - y0, length = dx * dx + dy * dy;
                for (int y = top; y <= bottom; y++) for (int x = left; x <= right; x++) {
                    float px = x + 0.5f - x0, py = y + 0.5f - y0;
                    float t = length == 0 ? 0 : Math.max(0, Math.min(1, (px * dx + py * dy) / length));
                    float ex = px - t * dx, ey = py - t * dy;
                    if (ex * ex + ey * ey <= limit) covered[y * width + x] = true;
                }
            }
        }
    }

    private void paint(boolean[] covered, Paint paint) {
        int width = bitmap.getWidth();
        for (int at = 0; at < covered.length; at++) if (covered[at]) {
            int x = at % width, y = at / width;
            bitmap.blend(x, y, paint.colorAt(x + 0.5f, y + 0.5f));
        }
    }
}
