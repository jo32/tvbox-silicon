package android.graphics;

/** A font choice. Canvas draws no text, so only its style is kept. */
public class Typeface {
    public static final int NORMAL = 0, BOLD = 1, ITALIC = 2, BOLD_ITALIC = 3;
    public static final Typeface DEFAULT = new Typeface(NORMAL), DEFAULT_BOLD = new Typeface(BOLD),
        SANS_SERIF = new Typeface(NORMAL), SERIF = new Typeface(NORMAL), MONOSPACE = new Typeface(NORMAL);
    private final int style;
    private Typeface(int style) { this.style = style; }
    public static Typeface create(Typeface family, int style) { return new Typeface(style); }
    public static Typeface create(String family, int style) { return new Typeface(style); }
    public static Typeface defaultFromStyle(int style) { return new Typeface(style); }
    public int getStyle() { return style; }
    public final boolean isBold() { return (style & BOLD) != 0; }
    public final boolean isItalic() { return (style & ITALIC) != 0; }
}
