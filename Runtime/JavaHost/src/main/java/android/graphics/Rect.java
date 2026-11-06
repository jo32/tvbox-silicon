package android.graphics;

public final class Rect {
    public int left, top, right, bottom;
    public Rect() { }
    public Rect(int left, int top, int right, int bottom) { set(left, top, right, bottom); }
    public Rect(Rect other) { if (other != null) set(other.left, other.top, other.right, other.bottom); }
    public void set(int left, int top, int right, int bottom) { this.left = left; this.top = top; this.right = right; this.bottom = bottom; }
    public void set(Rect other) { set(other.left, other.top, other.right, other.bottom); }
    public void setEmpty() { set(0, 0, 0, 0); }
    public int width() { return right - left; }
    public int height() { return bottom - top; }
    public int centerX() { return (left + right) >> 1; }
    public int centerY() { return (top + bottom) >> 1; }
    public boolean isEmpty() { return left >= right || top >= bottom; }
    public boolean contains(int x, int y) { return x >= left && x < right && y >= top && y < bottom; }
    public void offset(int dx, int dy) { left += dx; right += dx; top += dy; bottom += dy; }
    public void inset(int dx, int dy) { left += dx; right -= dx; top += dy; bottom -= dy; }
    @Override public boolean equals(Object o) { return o instanceof Rect r && r.left == left && r.top == top && r.right == right && r.bottom == bottom; }
    @Override public int hashCode() { return ((left * 31 + top) * 31 + right) * 31 + bottom; }
    @Override public String toString() { return "Rect(" + left + ", " + top + " - " + right + ", " + bottom + ")"; }
}
