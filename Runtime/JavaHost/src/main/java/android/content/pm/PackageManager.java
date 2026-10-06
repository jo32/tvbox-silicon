package android.content.pm;

/** Minimal PackageManager: no other packages are installed on this host. */
public class PackageManager {
    public static final int GET_META_DATA = 128;
    public static class NameNotFoundException extends Exception {
        public NameNotFoundException() { }
        public NameNotFoundException(String message) { super(message); }
    }
    public PackageInfo getPackageInfo(String packageName, int flags) throws NameNotFoundException {
        PackageInfo info = new PackageInfo();
        info.applicationInfo = getApplicationInfo(packageName, flags);
        info.packageName = packageName; info.versionName = "1.0"; info.versionCode = 1;
        return info;
    }
    public ApplicationInfo getApplicationInfo(String packageName, int flags) throws NameNotFoundException {
        var application = com.github.catvod.spider.Init.application;
        if (application == null || !application.getPackageName().equals(packageName)) throw new NameNotFoundException(packageName);
        ApplicationInfo info = new ApplicationInfo();
        info.packageName = packageName; info.name = "Yingxia";
        info.dataDir = application.getFilesDir().getParent();
        info.sourceDir = tvbox.runtime.HostEnvironment.plugin(); info.publicSourceDir = info.sourceDir;
        return info;
    }
    public boolean hasSystemFeature(String name) { return false; }
}
