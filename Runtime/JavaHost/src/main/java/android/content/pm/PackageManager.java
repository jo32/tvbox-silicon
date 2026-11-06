package android.content.pm;

/** Minimal PackageManager: no other packages are installed on this host. */
public class PackageManager {
    public static final int GET_SIGNATURES = 64;
    public static final int GET_META_DATA = 128;
    /** A fixed stand-in certificate: there is no APK, but plugins expect one to hash. */
    private static final Signature HOST_SIGNATURE = new Signature("Yingxia host".getBytes(java.nio.charset.StandardCharsets.UTF_8));
    public static class NameNotFoundException extends Exception {
        public NameNotFoundException() { }
        public NameNotFoundException(String message) { super(message); }
    }
    public PackageInfo getPackageInfo(String packageName, int flags) throws NameNotFoundException {
        PackageInfo info = new PackageInfo();
        info.applicationInfo = getApplicationInfo(packageName, flags);
        info.packageName = packageName; info.versionName = "1.0"; info.versionCode = 1;
        info.signatures = new Signature[] { HOST_SIGNATURE };
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
    public CharSequence getApplicationLabel(ApplicationInfo info) { return info.loadLabel(this); }
    /** Only this app is installed: there are no other apps or providers to find or open. */
    public java.util.List<ApplicationInfo> getInstalledApplications(int flags) { return new java.util.ArrayList<>(); }
    public java.util.List<PackageInfo> getInstalledPackages(int flags) { return new java.util.ArrayList<>(); }
    public android.content.Intent getLaunchIntentForPackage(String packageName) { return null; }
    public android.content.Intent getLeanbackLaunchIntentForPackage(String packageName) { return null; }
    public ProviderInfo resolveContentProvider(String authority, int flags) { return null; }
    public ResolveInfo resolveActivity(android.content.Intent intent, int flags) { return null; }
    public java.util.List<ResolveInfo> queryIntentActivities(android.content.Intent intent, int flags) { return new java.util.ArrayList<>(); }
    public int checkPermission(String permission, String packageName) { return 0; }
    public boolean hasSystemFeature(String name) { return false; }
}
