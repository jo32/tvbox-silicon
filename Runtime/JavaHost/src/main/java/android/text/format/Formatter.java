package android.text.format;

import java.util.Locale;

/** Sizes in decimal units (Android 8+) and IPv4 addresses from Android's little-endian ints. */
public final class Formatter {
    private Formatter() { }
    public static String formatIpAddress(int ip) {
        return (ip & 255) + "." + (ip >>> 8 & 255) + "." + (ip >>> 16 & 255) + "." + (ip >>> 24 & 255);
    }
    public static String formatFileSize(android.content.Context context, long bytes) { return size(bytes, false); }
    public static String formatShortFileSize(android.content.Context context, long bytes) { return size(bytes, true); }
    private static String size(long bytes, boolean shorter) {
        String[] units = {"B", "kB", "MB", "GB", "TB", "PB"};
        double value = Math.abs((double) bytes);
        int unit = 0;
        while (value > 900 && unit < units.length - 1) { value /= 1000; unit++; }
        String pattern = unit == 0 || value >= 100 ? "%.0f" : shorter ? (value < 10 ? "%.1f" : "%.0f") : "%.2f";
        return (bytes < 0 ? "-" : "") + String.format(Locale.US, pattern, value) + " " + units[unit];
    }
}
