package android.graphics;

public final class Color {
    public static final int BLACK = 0xff000000, WHITE = 0xffffffff, TRANSPARENT = 0;
    public static int argb(int a, int r, int g, int b) { return (a << 24) | (r << 16) | (g << 8) | b; }
    public static int rgb(int r, int g, int b) { return argb(255, r, g, b); }
    public static int alpha(int color) { return color >>> 24; }
    public static int red(int color) { return (color >> 16) & 255; }
    public static int green(int color) { return (color >> 8) & 255; }
    public static int blue(int color) { return color & 255; }
    public static int parseColor(String text) {
        if (text.startsWith("#")) {
            long value = Long.parseLong(text.substring(1), 16);
            if (text.length() == 7) return (int) (value | 0xff000000L);
            if (text.length() == 9) return (int) value;
            throw new IllegalArgumentException("Unknown color: " + text);
        }
        return switch (text.toLowerCase(java.util.Locale.ROOT)) {
            case "black" -> BLACK; case "white" -> WHITE; case "transparent" -> TRANSPARENT;
            case "red" -> 0xffff0000; case "green", "lime" -> 0xff00ff00; case "blue" -> 0xff0000ff;
            case "yellow" -> 0xffffff00; case "cyan", "aqua" -> 0xff00ffff; case "magenta", "fuchsia" -> 0xffff00ff;
            case "gray", "grey" -> 0xff888888; case "darkgray", "darkgrey" -> 0xff444444; case "lightgray", "lightgrey" -> 0xffcccccc;
            case "maroon" -> 0xff800000; case "navy" -> 0xff000080; case "olive" -> 0xff808000; case "purple" -> 0xff800080;
            case "silver" -> 0xffc0c0c0; case "teal" -> 0xff008080;
            default -> throw new IllegalArgumentException("Unknown color: " + text);
        };
    }
}
