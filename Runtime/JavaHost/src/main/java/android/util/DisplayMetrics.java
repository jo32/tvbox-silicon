package android.util;

/** A 1080p TV at xhdpi. */
public class DisplayMetrics {
    public static final int DENSITY_DEFAULT = 160, DENSITY_XHIGH = 320;
    public static final int WIDTH = 1920, HEIGHT = 1080;
    public int widthPixels, heightPixels, densityDpi;
    public float density, scaledDensity, xdpi, ydpi;
    public DisplayMetrics() { setToDefaults(); }
    public void setToDefaults() {
        widthPixels = WIDTH; heightPixels = HEIGHT; densityDpi = DENSITY_XHIGH;
        density = 2f; scaledDensity = 2f; xdpi = ydpi = DENSITY_XHIGH;
    }
    public void setTo(DisplayMetrics other) {
        widthPixels = other.widthPixels; heightPixels = other.heightPixels; densityDpi = other.densityDpi;
        density = other.density; scaledDensity = other.scaledDensity; xdpi = other.xdpi; ydpi = other.ydpi;
    }
}
