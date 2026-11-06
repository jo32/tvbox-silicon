package android.content.res;

import android.graphics.drawable.Drawable;
import android.util.DisplayMetrics;
import android.util.TypedValue;

/** No resources ship with a plugin: lookups find nothing, while the screen's size and density are real. */
public class Resources {
    private static final Resources SYSTEM = new Resources();
    private final DisplayMetrics metrics = new DisplayMetrics();
    private final Configuration configuration = new Configuration();

    public static class NotFoundException extends RuntimeException {
        public NotFoundException() { }
        public NotFoundException(String name) { super(name); }
    }

    public final class Theme {
        public boolean resolveAttribute(int resid, TypedValue outValue, boolean resolveRefs) { return false; }
        public void applyStyle(int resId, boolean force) { }
        public Resources getResources() { return Resources.this; }
    }

    public static Resources getSystem() { return SYSTEM; }
    public DisplayMetrics getDisplayMetrics() { return metrics; }
    public Configuration getConfiguration() { return configuration; }
    public final Theme newTheme() { return new Theme(); }
    public int getIdentifier(String name, String type, String pkg) { return 0; }
    public String getString(int id) { return tvbox.runtime.PluginWindows.systemString(id); }
    public String getString(int id, Object... args) { return String.format(getString(id), args); }
    public CharSequence getText(int id) { return getString(id); }
    public String[] getStringArray(int id) { return new String[0]; }
    public int getColor(int id) { return 0xFF000000; }
    public int getColor(int id, Theme theme) { return getColor(id); }
    public ColorStateList getColorStateList(int id) { return ColorStateList.valueOf(getColor(id)); }
    public float getDimension(int id) { return 0f; }
    public int getDimensionPixelSize(int id) { return 0; }
    public int getDimensionPixelOffset(int id) { return 0; }
    public int getInteger(int id) { return 0; }
    public boolean getBoolean(int id) { return false; }
    public Drawable getDrawable(int id) { return null; }
    public Drawable getDrawable(int id, Theme theme) { return null; }
    public String getResourceName(int id) { throw new NotFoundException("#" + Integer.toHexString(id)); }
    public String getResourceEntryName(int id) { return getResourceName(id); }
    public java.io.InputStream openRawResource(int id) { throw new NotFoundException("#" + Integer.toHexString(id)); }
    public void getValue(int id, TypedValue value, boolean resolveRefs) { throw new NotFoundException("#" + Integer.toHexString(id)); }
}
