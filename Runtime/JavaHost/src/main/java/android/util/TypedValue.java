package android.util;

public class TypedValue {
    public static final int COMPLEX_UNIT_PX = 0, COMPLEX_UNIT_DIP = 1, COMPLEX_UNIT_SP = 2, COMPLEX_UNIT_PT = 3,
        COMPLEX_UNIT_IN = 4, COMPLEX_UNIT_MM = 5, TYPE_NULL = 0, TYPE_REFERENCE = 1, TYPE_INT_COLOR_ARGB8 = 28;
    public int type, data, resourceId, assetCookie, changingConfigurations, density;
    public CharSequence string;
    public TypedValue() { }
    public static float applyDimension(int unit, float value, DisplayMetrics metrics) {
        DisplayMetrics m = metrics == null ? new DisplayMetrics() : metrics;
        return switch (unit) {
            case COMPLEX_UNIT_DIP -> value * m.density;
            case COMPLEX_UNIT_SP -> value * m.scaledDensity;
            case COMPLEX_UNIT_PT -> value * m.xdpi / 72f;
            case COMPLEX_UNIT_IN -> value * m.xdpi;
            case COMPLEX_UNIT_MM -> value * m.xdpi / 25.4f;
            default -> value;
        };
    }
    public float getDimension(DisplayMetrics metrics) { return data; }
    public int getComplexUnit() { return COMPLEX_UNIT_PX; }
}
