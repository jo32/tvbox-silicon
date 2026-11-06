package android.content;

import android.net.Uri;
import java.util.HashMap;
import java.util.Map;

/** The pages and shares a plugin opens; the app opens the address (tvbox.runtime.PluginWindows.open). */
public class Intent implements Cloneable {
    public static final String ACTION_VIEW = "android.intent.action.VIEW", ACTION_SEND = "android.intent.action.SEND",
        ACTION_CHOOSER = "android.intent.action.CHOOSER", ACTION_MAIN = "android.intent.action.MAIN",
        EXTRA_TEXT = "android.intent.extra.TEXT", EXTRA_INTENT = "android.intent.extra.INTENT",
        EXTRA_TITLE = "android.intent.extra.TITLE", CATEGORY_BROWSABLE = "android.intent.category.BROWSABLE",
        CATEGORY_DEFAULT = "android.intent.category.DEFAULT";
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000, FLAG_ACTIVITY_CLEAR_TOP = 0x04000000;
    private String action, type, packageName;
    private Uri data;
    private int flags;
    private ComponentName component;
    private final Map<String, Object> extras = new HashMap<>();

    public Intent() { }
    public Intent(String action) { this.action = action; }
    public Intent(String action, Uri data) { this.action = action; this.data = data; }
    public Intent(Context context, Class<?> target) { component = new ComponentName(context.getPackageName(), target.getName()); }
    public Intent(Intent other) {
        action = other.action; type = other.type; packageName = other.packageName; data = other.data;
        flags = other.flags; component = other.component; extras.putAll(other.extras);
    }

    public static Intent createChooser(Intent target, CharSequence title) {
        return new Intent(ACTION_CHOOSER).putExtra(EXTRA_INTENT, target).putExtra(EXTRA_TITLE, title);
    }
    public String getAction() { return action; }
    public Intent setAction(String value) { action = value; return this; }
    public Uri getData() { return data; }
    public String getDataString() { return data == null ? null : data.toString(); }
    public Intent setData(Uri value) { data = value; type = null; return this; }
    public Intent setDataAndType(Uri value, String mime) { data = value; type = mime; return this; }
    public Intent setType(String mime) { type = mime; data = null; return this; }
    public String getType() { return type; }
    public Intent addFlags(int value) { flags |= value; return this; }
    public Intent setFlags(int value) { flags = value; return this; }
    public int getFlags() { return flags; }
    public Intent addCategory(String category) { return this; }
    public Intent setPackage(String value) { packageName = value; return this; }
    public String getPackage() { return packageName; }
    public Intent setComponent(ComponentName value) { component = value; return this; }
    public ComponentName getComponent() { return component; }
    public Intent setClassName(String pkg, String cls) { component = new ComponentName(pkg, cls); return this; }
    public Intent setClassName(Context context, String cls) { return setClassName(context.getPackageName(), cls); }
    /** Something can open a page or a shared text; nothing else. */
    public ComponentName resolveActivity(android.content.pm.PackageManager manager) {
        return data != null || extras.containsKey(EXTRA_TEXT) || extras.containsKey(EXTRA_INTENT) ? new ComponentName("tvbox", "browser") : null;
    }
    public Intent putExtra(String name, String value) { extras.put(name, value); return this; }
    public Intent putExtra(String name, CharSequence value) { extras.put(name, value); return this; }
    public Intent putExtra(String name, int value) { extras.put(name, value); return this; }
    public Intent putExtra(String name, long value) { extras.put(name, value); return this; }
    public Intent putExtra(String name, boolean value) { extras.put(name, value); return this; }
    public Intent putExtra(String name, Intent value) { extras.put(name, value); return this; }
    public String getStringExtra(String name) { Object value = extras.get(name); return value == null ? null : value.toString(); }
    public CharSequence getCharSequenceExtra(String name) { Object value = extras.get(name); return value instanceof CharSequence text ? text : null; }
    public int getIntExtra(String name, int fallback) { return extras.get(name) instanceof Integer value ? value : fallback; }
    public long getLongExtra(String name, long fallback) { return extras.get(name) instanceof Long value ? value : fallback; }
    public boolean getBooleanExtra(String name, boolean fallback) { return extras.get(name) instanceof Boolean value ? value : fallback; }
    public boolean hasExtra(String name) { return extras.containsKey(name); }
    public Intent getChooserTarget() { return extras.get(EXTRA_INTENT) instanceof Intent inner ? inner : null; }
    @Override public Object clone() { return new Intent(this); }
    @Override public String toString() { return "Intent { act=" + action + " dat=" + data + " }"; }
}
