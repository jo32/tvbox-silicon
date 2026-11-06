package android.view;

import android.util.DisplayMetrics;

/** A 1080p TV screen, which is what TVBox plugins lay their dialogs out for. */
public final class Display {
    public static final int DEFAULT_DISPLAY = 0;
    public void getMetrics(DisplayMetrics metrics) { metrics.setToDefaults(); }
    public void getRealMetrics(DisplayMetrics metrics) { metrics.setToDefaults(); }
    public void getSize(android.graphics.Point size) { size.x = DisplayMetrics.WIDTH; size.y = DisplayMetrics.HEIGHT; }
    public void getRealSize(android.graphics.Point size) { getSize(size); }
    public int getWidth() { return DisplayMetrics.WIDTH; }
    public int getHeight() { return DisplayMetrics.HEIGHT; }
    public int getRotation() { return 0; }
    public int getDisplayId() { return DEFAULT_DISPLAY; }
    public float getRefreshRate() { return 60f; }
}
