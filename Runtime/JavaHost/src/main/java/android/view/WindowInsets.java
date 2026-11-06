package android.view;

import android.graphics.Insets;

/** A TV screen has no bars or cutouts. */
public final class WindowInsets {
    public static final WindowInsets CONSUMED = new WindowInsets();
    public static final class Type {
        private Type() { }
        public static int statusBars() { return 1; }
        public static int navigationBars() { return 2; }
        public static int captionBar() { return 4; }
        public static int ime() { return 8; }
        public static int systemBars() { return 7; }
        public static int displayCutout() { return 128; }
    }
    public Insets getInsets(int typeMask) { return Insets.NONE; }
    public Insets getInsetsIgnoringVisibility(int typeMask) { return Insets.NONE; }
    public boolean isVisible(int typeMask) { return false; }
    public int getSystemWindowInsetTop() { return 0; }
    public int getSystemWindowInsetBottom() { return 0; }
    public int getSystemWindowInsetLeft() { return 0; }
    public int getSystemWindowInsetRight() { return 0; }
    public int getStableInsetTop() { return 0; }
    public int getStableInsetBottom() { return 0; }
}
