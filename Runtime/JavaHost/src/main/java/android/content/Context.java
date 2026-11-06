package android.content;
import java.io.File;
public class Context {
    private final File root;
    private final java.util.Map<String, SharedPreferences> preferences = new java.util.concurrent.ConcurrentHashMap<>();
    private final ClassLoader loader;
    public Context(File root, ClassLoader loader) { this.root = root; this.loader = loader; root.mkdirs(); }
    protected Context(Context base) { this(base.root, base.loader); }
    public File getCacheDir() { File dir = new File(root, "cache"); dir.mkdirs(); return dir; }
    public File getCodeCacheDir() { File dir = new File(root, "code_cache"); dir.mkdirs(); return dir; }
    public File getFilesDir() { File dir = new File(root, "files"); dir.mkdirs(); return dir; }
    public File getNoBackupFilesDir() { File dir = new File(root, "no_backup"); dir.mkdirs(); return dir; }
    public File getDatabasePath(String name) { File folder = new File(root, "databases"); folder.mkdirs(); return new File(folder, name); }
    public String getPackageName() { return "com.fongmi.android.tv"; }
    public ClassLoader getClassLoader() { return loader; }
    public SharedPreferences getSharedPreferences(String name, int mode) {
        String safe = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(name.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        return preferences.computeIfAbsent(name, key -> new tvbox.runtime.FilePreferences(new File(getFilesDir(), "prefs/"+safe+".json").toPath()));
    }
    public Context getApplicationContext() { return this; }
    /** The system services plugins use; others are unavailable (null), which Android also allows. */
    public Object getSystemService(String name) {
        if (name == null) return null;
        return switch (name) {
            case "window" -> android.view.WindowManager.DEFAULT;
            case "input_method" -> new android.view.inputmethod.InputMethodManager();
            case "connectivity" -> new android.net.ConnectivityManager();
            case "wifi" -> new android.net.wifi.WifiManager();
            case "clipboard" -> new ClipboardManager();
            case "phone" -> new android.telephony.TelephonyManager();
            default -> null;
        };
    }
    @SuppressWarnings("unchecked")
    public final <T> T getSystemService(Class<T> type) {
        String name = getSystemServiceName(type);
        return name == null ? null : (T) getSystemService(name);
    }
    public String getSystemServiceName(Class<?> type) {
        if (type == null) return null;
        return switch (type.getName()) {
            case "android.view.WindowManager" -> "window";
            case "android.view.inputmethod.InputMethodManager" -> "input_method";
            case "android.net.ConnectivityManager" -> "connectivity";
            case "android.net.wifi.WifiManager" -> "wifi";
            case "android.content.ClipboardManager" -> "clipboard";
            case "android.telephony.TelephonyManager" -> "phone";
            default -> null;
        };
    }
    public android.content.res.Resources getResources() { return android.content.res.Resources.getSystem(); }
    public android.content.res.Resources.Theme getTheme() { return getResources().newTheme(); }
    public void setTheme(int resid) { }
    public final String getString(int id) { return getResources().getString(id); }
    public final String getString(int id, Object... args) { return getResources().getString(id, args); }
    public final CharSequence getText(int id) { return getResources().getText(id); }
    public final int getColor(int id) { return getResources().getColor(id); }
    public final android.graphics.drawable.Drawable getDrawable(int id) { return getResources().getDrawable(id); }
    public final android.content.res.ColorStateList getColorStateList(int id) { return getResources().getColorStateList(id); }
    public android.os.Looper getMainLooper() { return android.os.Looper.getMainLooper(); }
    /** Pages a plugin opens go to the app (tvbox.runtime.PluginWindows). */
    public void startActivity(Intent intent) { tvbox.runtime.PluginWindows.open(intent); }
    public void startActivity(Intent intent, android.os.Bundle options) { startActivity(intent); }
    public int checkCallingOrSelfPermission(String permission) { return 0; }
    public int checkSelfPermission(String permission) { return 0; }
    public int checkPermission(String permission, int pid, int uid) { return 0; }
    public android.content.pm.PackageManager getPackageManager() { return new android.content.pm.PackageManager(); }
    public ContentResolver getContentResolver() { return new ContentResolver(); }
    public android.content.res.AssetManager getAssets() { return new android.content.res.AssetManager(loader); }
    public android.content.pm.ApplicationInfo getApplicationInfo() {
        try { return getPackageManager().getApplicationInfo(getPackageName(), 0); }
        catch (android.content.pm.PackageManager.NameNotFoundException error) { throw new IllegalStateException(error); }
    }
    public String getPackageCodePath() { return getApplicationInfo().sourceDir; }
    public String getPackageResourcePath() { return getApplicationInfo().publicSourceDir; }
    public File getDir(String name, int mode) { File dir = new File(root, "app_" + name); dir.mkdirs(); return dir; }
}
