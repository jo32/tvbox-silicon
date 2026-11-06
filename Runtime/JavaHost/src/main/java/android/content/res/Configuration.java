package android.content.res;

public final class Configuration {
    public static final int ORIENTATION_PORTRAIT = 1, ORIENTATION_LANDSCAPE = 2, UI_MODE_TYPE_MASK = 0x0f,
        UI_MODE_TYPE_NORMAL = 1, UI_MODE_TYPE_TELEVISION = 4, UI_MODE_NIGHT_MASK = 0x30, UI_MODE_NIGHT_YES = 0x20,
        SCREENLAYOUT_SIZE_MASK = 0x0f, SCREENLAYOUT_SIZE_XLARGE = 4, KEYBOARD_NOKEYS = 1, TOUCHSCREEN_NOTOUCH = 1;
    public int orientation = ORIENTATION_LANDSCAPE, uiMode = UI_MODE_TYPE_TELEVISION | UI_MODE_NIGHT_YES,
        screenWidthDp = 960, screenHeightDp = 540, smallestScreenWidthDp = 540, densityDpi = 320,
        screenLayout = SCREENLAYOUT_SIZE_XLARGE, keyboard = KEYBOARD_NOKEYS, touchscreen = TOUCHSCREEN_NOTOUCH;
    public float fontScale = 1f;
    public java.util.Locale locale = java.util.Locale.getDefault();
    public Configuration() { }
    public Configuration(Configuration other) { setTo(other); }
    public void setTo(Configuration o) {
        orientation = o.orientation; uiMode = o.uiMode; screenWidthDp = o.screenWidthDp; screenHeightDp = o.screenHeightDp;
        smallestScreenWidthDp = o.smallestScreenWidthDp; densityDpi = o.densityDpi; fontScale = o.fontScale; locale = o.locale;
    }
    public boolean isNightModeActive() { return (uiMode & UI_MODE_NIGHT_MASK) == UI_MODE_NIGHT_YES; }
}
