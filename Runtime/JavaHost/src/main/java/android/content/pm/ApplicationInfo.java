package android.content.pm;

public class ApplicationInfo {
    public String packageName;
    public String name;
    public String sourceDir;
    public String publicSourceDir;
    public String dataDir;
    public int flags;
    public int banner, icon, logo, labelRes, uid;
    public String processName, nativeLibraryDir;
    public int targetSdkVersion = 23;
    public CharSequence loadLabel(PackageManager manager) { return "TVBox"; }
}
