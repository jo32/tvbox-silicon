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
    public boolean hasSystemFeature(String name) { return false; }
}
