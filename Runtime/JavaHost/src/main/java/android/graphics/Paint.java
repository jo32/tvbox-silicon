package android.graphics;

/** What Canvas draws with: a color or gradient, fill or stroke, and a stroke width. Text settings are kept but unused. */
public class Paint {
    public static final int ANTI_ALIAS_FLAG = 1, FILTER_BITMAP_FLAG = 2, DITHER_FLAG = 4;
    public enum Style { FILL, STROKE, FILL_AND_STROKE }
    public enum Cap { BUTT, ROUND, SQUARE }
    public enum Join { MITER, ROUND, BEVEL }
    public enum Align { LEFT, CENTER, RIGHT }
    public static class FontMetrics { public float top, ascent, descent, bottom, leading; }

    private int flags, color = 0xff000000;
    private Style style = Style.FILL;
    private Cap cap = Cap.BUTT;
    private Join join = Join.MITER;
    private Align align = Align.LEFT;
    private float strokeWidth, textSize = 12;
    private Shader shader;
    private Typeface typeface;

    public Paint() { }
    public Paint(int flags) { this.flags = flags; }
    public Paint(Paint other) {
        flags = other.flags; color = other.color; style = other.style; cap = other.cap; join = other.join; align = other.align;
        strokeWidth = other.strokeWidth; textSize = other.textSize; shader = other.shader; typeface = other.typeface;
    }

    public int getFlags() { return flags; }
    public void setFlags(int value) { flags = value; }
    public boolean isAntiAlias() { return (flags & ANTI_ALIAS_FLAG) != 0; }
    public void setAntiAlias(boolean on) { flags = on ? flags | ANTI_ALIAS_FLAG : flags & ~ANTI_ALIAS_FLAG; }
    public void setDither(boolean on) { }
    public int getColor() { return color; }
    public void setColor(int value) { color = value; }
    public int getAlpha() { return color >>> 24; }
    public void setAlpha(int alpha) { color = (color & 0xffffff) | ((alpha & 255) << 24); }
    public void setARGB(int a, int r, int g, int b) { color = Color.argb(a, r, g, b); }
    public Style getStyle() { return style; }
    public void setStyle(Style value) { style = value == null ? Style.FILL : value; }
    public Cap getStrokeCap() { return cap; }
    public void setStrokeCap(Cap value) { cap = value; }
    public Join getStrokeJoin() { return join; }
    public void setStrokeJoin(Join value) { join = value; }
    public float getStrokeWidth() { return strokeWidth; }
    public void setStrokeWidth(float value) { strokeWidth = value; }
    public Shader getShader() { return shader; }
    public Shader setShader(Shader value) { shader = value; return value; }
    public Typeface getTypeface() { return typeface; }
    public Typeface setTypeface(Typeface value) { typeface = value; return value; }
    public float getTextSize() { return textSize; }
    public void setTextSize(float value) { textSize = value; }
    public Align getTextAlign() { return align; }
    public void setTextAlign(Align value) { align = value; }
    public static final int FAKE_BOLD_TEXT_FLAG = 0x20;
    public void setFakeBoldText(boolean on) { flags = on ? flags | FAKE_BOLD_TEXT_FLAG : flags & ~FAKE_BOLD_TEXT_FLAG; }
    public boolean isFakeBoldText() { return (flags & FAKE_BOLD_TEXT_FLAG) != 0; }
    /** Typical sans-serif proportions of the text size. */
    public FontMetrics getFontMetrics() {
        FontMetrics metrics = new FontMetrics();
        metrics.top = -1.06f * textSize; metrics.ascent = -0.93f * textSize; metrics.descent = 0.24f * textSize; metrics.bottom = 0.27f * textSize;
        return metrics;
    }
    public float measureText(String text) { return text == null ? 0 : text.length() * textSize * 0.6f; }

    public void reset() {
        flags = 0; color = 0xff000000; style = Style.FILL; cap = Cap.BUTT; join = Join.MITER; align = Align.LEFT;
        strokeWidth = 0; textSize = 12; shader = null; typeface = null;
    }
    public void set(Paint other) { if (other != this) { reset(); flags = other.flags; color = other.color; style = other.style; cap = other.cap; join = other.join; align = other.align; strokeWidth = other.strokeWidth; textSize = other.textSize; shader = other.shader; typeface = other.typeface; } }
    public boolean isFilterBitmap() { return (flags & FILTER_BITMAP_FLAG) != 0; }
    public void setFilterBitmap(boolean on) { flags = on ? flags | FILTER_BITMAP_FLAG : flags & ~FILTER_BITMAP_FLAG; }
    public boolean isDither() { return (flags & DITHER_FLAG) != 0; }

    int colorAt(float x, float y) { return shader != null ? shader.colorAt(x, y) : color; }
}
