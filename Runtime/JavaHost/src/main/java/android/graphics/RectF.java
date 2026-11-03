package android.graphics;

public class RectF {
    public float left, top, right, bottom;
    public RectF() { }
    public RectF(float left, float top, float right, float bottom) { set(left, top, right, bottom); }
    public RectF(RectF other) { if (other != null) set(other.left, other.top, other.right, other.bottom); }
    public void set(float left, float top, float right, float bottom) { this.left = left; this.top = top; this.right = right; this.bottom = bottom; }
    public final float width() { return right - left; }
    public final float height() { return bottom - top; }
    public final float centerX() { return (left + right) / 2; }
    public final float centerY() { return (top + bottom) / 2; }
    public final boolean isEmpty() { return left >= right || top >= bottom; }
}
