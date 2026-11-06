package android.text;

public class TextPaint extends android.graphics.Paint {
    public int bgColor, baselineShift, linkColor;
    public int[] drawableState;
    public float density = 2f;
    public TextPaint() { }
    public TextPaint(int flags) { super(flags); }
    public TextPaint(android.graphics.Paint paint) { super(paint); }
}
