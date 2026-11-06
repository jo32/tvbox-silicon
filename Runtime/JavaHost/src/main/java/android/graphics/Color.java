package android.graphics;

public final class Color {
    public static final int BLACK = 0xff000000, WHITE = 0xffffffff, TRANSPARENT = 0;
    public static int argb(int a, int r, int g, int b) { return (a << 24) | (r << 16) | (g << 8) | b; }
    public static int rgb(int r, int g, int b) { return argb(255, r, g, b); }
    public static int alpha(int color) { return color >>> 24; }
    public static int red(int color) { return (color >> 16) & 255; }
    public static int green(int color) { return (color >> 8) & 255; }
    public static int blue(int color) { return color & 255; }

    /** Hue in degrees [0, 360), saturation and value in [0, 1], as Android computes them. */
    public static void RGBToHSV(int red, int green, int blue, float[] hsv) {
        float r = (red & 255) / 255f, g = (green & 255) / 255f, b = (blue & 255) / 255f;
        float max = Math.max(r, Math.max(g, b)), min = Math.min(r, Math.min(g, b)), range = max - min;
        float hue = 0;
        if (range > 0) {
            if (max == r) hue = 60 * (((g - b) / range) % 6);
            else if (max == g) hue = 60 * ((b - r) / range + 2);
            else hue = 60 * ((r - g) / range + 4);
            if (hue < 0) hue += 360;
        }
        hsv[0] = hue; hsv[1] = max == 0 ? 0 : range / max; hsv[2] = max;
    }
    public static void colorToHSV(int color, float[] hsv) { RGBToHSV(red(color), green(color), blue(color), hsv); }
    public static int HSVToColor(float[] hsv) { return HSVToColor(255, hsv); }
    public static int HSVToColor(int alpha, float[] hsv) {
        float h = ((hsv[0] % 360) + 360) % 360, s = Math.max(0, Math.min(1, hsv[1])), v = Math.max(0, Math.min(1, hsv[2]));
        float c = v * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = v - c, r, g, b;
        switch ((int) (h / 60)) {
            case 0 -> { r = c; g = x; b = 0; }
            case 1 -> { r = x; g = c; b = 0; }
            case 2 -> { r = 0; g = c; b = x; }
            case 3 -> { r = 0; g = x; b = c; }
            case 4 -> { r = x; g = 0; b = c; }
            default -> { r = c; g = 0; b = x; }
        }
        return argb(alpha & 255, Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255));
    }
    public static int argb(float a, float r, float g, float b) { return argb(Math.round(a * 255), Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)); }
    public static int rgb(float r, float g, float b) { return argb(1f, r, g, b); }
    public static float luminance(int color) {
        double r = linear(red(color) / 255.0), g = linear(green(color) / 255.0), b = linear(blue(color) / 255.0);
        return (float) (0.2126 * r + 0.7152 * g + 0.0722 * b);
    }
    private static double linear(double c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
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
