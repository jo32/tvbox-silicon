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
    /** No Android system services exist here; callers already handle an unavailable service. */
    public Object getSystemService(String name) { return null; }
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
