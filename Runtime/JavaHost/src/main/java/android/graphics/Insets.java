package android.graphics;

public final class Insets {
    public static final Insets NONE = new Insets(0, 0, 0, 0);
    public final int left, top, right, bottom;
    private Insets(int left, int top, int right, int bottom) { this.left = left; this.top = top; this.right = right; this.bottom = bottom; }
    public static Insets of(int left, int top, int right, int bottom) { return left == 0 && top == 0 && right == 0 && bottom == 0 ? NONE : new Insets(left, top, right, bottom); }
    public static Insets of(Rect r) { return r == null ? NONE : of(r.left, r.top, r.right, r.bottom); }
}
