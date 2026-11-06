package android.graphics;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;

/**
 * Draws shapes and bitmaps into a Bitmap, for plugins that paint small images such as a config center's tile
 * icons (#360) or a color wheel. Every shape becomes straight segments, filled by the path's fill rule or
 * stroked with round ends, without antialiasing; clips are pixel masks and the matrix is a translation only.
 * Text is not drawn: there are no fonts here.
 */
public class Canvas {
    private final Bitmap bitmap;
    /** Pixels drawing may touch, or null for all of them. */
    private boolean[] clip;
    private float dx, dy;
    private final Deque<Object[]> saved = new ArrayDeque<>();

    public Canvas() { this(null); }
    public Canvas(Bitmap bitmap) { this.bitmap = bitmap; }

    public int getWidth() { return bitmap == null ? 0 : bitmap.getWidth(); }
    public int getHeight() { return bitmap == null ? 0 : bitmap.getHeight(); }
    public boolean isHardwareAccelerated() { return false; }
    public int save() { saved.push(new Object[]{clip == null ? null : clip.clone(), dx, dy}); return saved.size(); }
    public int saveLayer(RectF bounds, Paint paint) { return save(); }
    public int saveLayer(float l, float t, float r, float b, Paint paint) { return save(); }
    public int saveLayerAlpha(RectF bounds, int alpha) { return save(); }
    public void restore() {
        if (saved.isEmpty()) return;
        Object[] state = saved.pop();
        clip = (boolean[]) state[0]; dx = (Float) state[1]; dy = (Float) state[2];
    }
    public int getSaveCount() { return saved.size() + 1; }
    public void restoreToCount(int count) { while (saved.size() >= Math.max(1, count)) restore(); }
    public void translate(float x, float y) { dx += x; dy += y; }

    public boolean clipPath(Path path) {
        if (bitmap == null) return false;
        boolean[] inside = new boolean[bitmap.getWidth() * bitmap.getHeight()];
        fill(moved(path.contours()), inside, path.evenOdd());
        return intersect(inside);
    }
    public boolean clipRect(float left, float top, float right, float bottom) {
        if (bitmap == null) return false;
        int width = bitmap.getWidth(), height = bitmap.getHeight();
        boolean[] inside = new boolean[width * height];
        int l = Math.max(0, Math.round(left + dx)), t = Math.max(0, Math.round(top + dy));
        int r = Math.min(width, Math.round(right + dx)), b = Math.min(height, Math.round(bottom + dy));
        for (int y = t; y < b; y++) for (int x = l; x < r; x++) inside[y * width + x] = true;
        return intersect(inside);
    }
    public boolean clipRect(RectF rect) { return clipRect(rect.left, rect.top, rect.right, rect.bottom); }
    public boolean clipRect(Rect rect) { return clipRect(rect.left, rect.top, rect.right, rect.bottom); }
    public boolean clipRect(int left, int top, int right, int bottom) { return clipRect((float) left, top, right, bottom); }
    private boolean intersect(boolean[] inside) {
        boolean any = false;
        for (int i = 0; i < inside.length; i++) { if (clip != null && !clip[i]) inside[i] = false; any |= inside[i]; }
        clip = inside;
        return any;
    }

    public void drawColor(int color) {
        if (bitmap == null) return;
        for (int y = 0; y < bitmap.getHeight(); y++) for (int x = 0; x < bitmap.getWidth(); x++) put(x, y, color);
    }
    public void drawARGB(int a, int r, int g, int b) { drawColor(Color.argb(a, r, g, b)); }
    public void drawRGB(int r, int g, int b) { drawColor(Color.rgb(r, g, b)); }
    public void drawPaint(Paint paint) {
        if (bitmap == null) return;
        for (int y = 0; y < bitmap.getHeight(); y++) for (int x = 0; x < bitmap.getWidth(); x++) put(x, y, paint.colorAt(x + 0.5f - dx, y + 0.5f - dy));
    }
    public void drawRect(float left, float top, float right, float bottom, Paint paint) {
        draw(List.of(new float[]{left, top, right, top, right, bottom, left, bottom, left, top}), paint, false);
    }
    public void drawRect(RectF rect, Paint paint) { drawRect(rect.left, rect.top, rect.right, rect.bottom, paint); }
    public void drawRect(Rect rect, Paint paint) { drawRect(rect.left, rect.top, rect.right, rect.bottom, paint); }
    public void drawRoundRect(RectF rect, float rx, float ry, Paint paint) {
        Path path = new Path();
        path.addRoundRect(rect, rx, ry, Path.Direction.CW);
        drawPath(path, paint);
    }
    public void drawRoundRect(float left, float top, float right, float bottom, float rx, float ry, Paint paint) { drawRoundRect(new RectF(left, top, right, bottom), rx, ry, paint); }
    public void drawCircle(float cx, float cy, float radius, Paint paint) { drawOval(new RectF(cx - radius, cy - radius, cx + radius, cy + radius), paint); }
    public void drawOval(RectF oval, Paint paint) { drawPath(arc(oval, 0, 360, false, true), paint); }
    public void drawOval(float left, float top, float right, float bottom, Paint paint) { drawOval(new RectF(left, top, right, bottom), paint); }
    public void drawArc(RectF oval, float startAngle, float sweepAngle, boolean useCenter, Paint paint) {
        drawPath(arc(oval, startAngle, sweepAngle, useCenter, useCenter || Math.abs(sweepAngle) >= 360), paint);
    }
    public void drawArc(float left, float top, float right, float bottom, float startAngle, float sweepAngle, boolean useCenter, Paint paint) {
        drawArc(new RectF(left, top, right, bottom), startAngle, sweepAngle, useCenter, paint);
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
        stroke(moved(List.of(new float[]{startX, startY, stopX, stopY})), Math.max(1, paint.getStrokeWidth()), covered);
        paint(covered, paint);
    }
    public void drawLines(float[] points, Paint paint) { for (int i = 0; i + 3 < points.length; i += 4) drawLine(points[i], points[i + 1], points[i + 2], points[i + 3], paint); }
    public void drawPoint(float x, float y, Paint paint) { drawCircle(x, y, Math.max(0.5f, paint.getStrokeWidth() / 2), paint); }
    public void drawPath(Path path, Paint paint) { draw(path.contours(), paint, path.evenOdd()); }
    public void drawText(String text, float x, float y, Paint paint) { }
    public void drawText(CharSequence text, int start, int end, float x, float y, Paint paint) { }
    public void drawText(char[] text, int index, int count, float x, float y, Paint paint) { }
    public void drawText(String text, int start, int end, float x, float y, Paint paint) { }

    /** The bitmap at (left, top), unscaled. */
    public void drawBitmap(Bitmap source, float left, float top, Paint paint) {
        if (source == null) return;
        drawBitmap(source, null, new RectF(left, top, left + source.getWidth(), top + source.getHeight()), paint);
    }
    public void drawBitmap(Bitmap source, Rect from, Rect to, Paint paint) {
        drawBitmap(source, from, to == null ? null : new RectF(to.left, to.top, to.right, to.bottom), paint);
    }
    /** The `from` part of the bitmap (all of it when null) scaled into `to`, nearest pixel. */
    public void drawBitmap(Bitmap source, Rect from, RectF to, Paint paint) {
        if (bitmap == null || source == null || to == null || to.isEmpty()) return;
        Rect src = from != null ? from : new Rect(0, 0, source.getWidth(), source.getHeight());
        if (src.isEmpty()) return;
        int alpha = paint == null ? 255 : paint.getAlpha();
        int l = (int) Math.floor(to.left + dx), t = (int) Math.floor(to.top + dy), r = (int) Math.ceil(to.right + dx), b = (int) Math.ceil(to.bottom + dy);
        for (int y = Math.max(0, t); y < Math.min(bitmap.getHeight(), b); y++) {
            float fy = (y + 0.5f - dy - to.top) / to.height();
            int sy = src.top + (int) Math.floor(fy * src.height());
            if (sy < src.top || sy >= src.bottom || sy < 0 || sy >= source.getHeight()) continue;
            for (int x = Math.max(0, l); x < Math.min(bitmap.getWidth(), r); x++) {
                float fx = (x + 0.5f - dx - to.left) / to.width();
                int sx = src.left + (int) Math.floor(fx * src.width());
                if (sx < src.left || sx >= src.right || sx < 0 || sx >= source.getWidth()) continue;
                int color = source.pixels[sy * source.getWidth() + sx];
                if (alpha < 255) color = (color & 0xffffff) | (((color >>> 24) * alpha / 255) << 24);
                put(x, y, color);
            }
        }
    }

    private void put(int x, int y, int color) {
        if (clip != null && (x < 0 || y < 0 || x >= bitmap.getWidth() || y >= bitmap.getHeight() || !clip[y * bitmap.getWidth() + x])) return;
        bitmap.blend(x, y, color);
    }
    private List<float[]> moved(List<float[]> contours) {
        if (dx == 0 && dy == 0) return contours;
        List<float[]> out = new ArrayList<>(contours.size());
        for (float[] points : contours) {
            float[] copy = points.clone();
            for (int i = 0; i + 1 < copy.length; i += 2) { copy[i] += dx; copy[i + 1] += dy; }
            out.add(copy);
        }
        return out;
    }

    private void draw(List<float[]> contours, Paint paint, boolean evenOdd) {
        if (bitmap == null || contours.isEmpty()) return;
        contours = moved(contours);
        boolean[] covered = new boolean[bitmap.getWidth() * bitmap.getHeight()];
        if (paint.getStyle() != Paint.Style.STROKE) fill(contours, covered, evenOdd);
        if (paint.getStyle() != Paint.Style.FILL) stroke(contours, Math.max(1, paint.getStrokeWidth()), covered);
        paint(covered, paint);
    }

    /** Pixels whose centres are inside the outline, by the nonzero winding rule (Android's default) or even-odd. */
    private void fill(List<float[]> contours, boolean[] covered, boolean evenOdd) {
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
                winding += evenOdd ? 1 : (int) crossings.get(i)[1];
                if (evenOdd ? winding % 2 == 0 : winding == 0) continue;
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
                float ddx = x1 - x0, ddy = y1 - y0, length = ddx * ddx + ddy * ddy;
                for (int y = top; y <= bottom; y++) for (int x = left; x <= right; x++) {
                    float px = x + 0.5f - x0, py = y + 0.5f - y0;
                    float t = length == 0 ? 0 : Math.max(0, Math.min(1, (px * ddx + py * ddy) / length));
                    float ex = px - t * ddx, ey = py - t * ddy;
                    if (ex * ex + ey * ey <= limit) covered[y * width + x] = true;
                }
            }
        }
    }

    /** Shaders are in the plugin's coordinates, before the translation. */
    private void paint(boolean[] covered, Paint paint) {
        int width = bitmap.getWidth();
        for (int at = 0; at < covered.length; at++) if (covered[at]) {
            int x = at % width, y = at / width;
            put(x, y, paint.colorAt(x + 0.5f - dx, y + 0.5f - dy));
        }
    }
}
