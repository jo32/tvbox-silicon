package android.content;

/**
 * Base class plugins extend for their own providers (a file provider). The host never publishes them; a
 * plugin may still create one and call it directly.
 */
public abstract class ContentProvider {
    private Context context;
    private String authority;
    public ContentProvider() { }
    public final Context getContext() { return context; }
    public final Context requireContext() { if (context == null) throw new IllegalStateException("Cannot find context from the provider."); return context; }
    public void attachInfo(Context context, android.content.pm.ProviderInfo info) {
        if (this.context != null) return;
        this.context = context;
        onCreate();
    }
    protected final void setAuthorities(String value) { authority = value; }
    public final String getCallingPackage() { return context == null ? null : context.getPackageName(); }
    public abstract boolean onCreate();
    public abstract android.database.Cursor query(android.net.Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder);
    public abstract String getType(android.net.Uri uri);
    public abstract android.net.Uri insert(android.net.Uri uri, ContentValues values);
    public abstract int delete(android.net.Uri uri, String selection, String[] selectionArgs);
    public abstract int update(android.net.Uri uri, ContentValues values, String selection, String[] selectionArgs);
    public android.os.ParcelFileDescriptor openFile(android.net.Uri uri, String mode) throws java.io.FileNotFoundException {
        throw new java.io.FileNotFoundException("No files supported by provider at " + uri);
    }
    public android.os.Bundle call(String method, String arg, android.os.Bundle extras) { return null; }
    public void shutdown() { }
    public void onLowMemory() { }
    public void onTrimMemory(int level) { }
}
