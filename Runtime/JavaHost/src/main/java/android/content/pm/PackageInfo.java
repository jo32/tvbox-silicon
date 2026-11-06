package android.content.pm;

/** Metadata for the compatibility host itself. */
public class PackageInfo {
    public String packageName;
    public String versionName;
    public int versionCode;
    public ApplicationInfo applicationInfo;
    public Signature[] signatures;
    public String[] requestedPermissions;
    public int[] requestedPermissionsFlags;
    public ProviderInfo[] providers;
    public long firstInstallTime, lastUpdateTime;
    public long getLongVersionCode() { return versionCode; }
}
