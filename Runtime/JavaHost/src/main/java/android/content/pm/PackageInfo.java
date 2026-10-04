package android.content.pm;

/** Metadata for the compatibility host itself. */
public class PackageInfo {
    public String packageName;
    public String versionName;
    public int versionCode;
    public ApplicationInfo applicationInfo;
    public long getLongVersionCode() { return versionCode; }
}
