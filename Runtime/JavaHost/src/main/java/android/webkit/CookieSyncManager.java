package android.webkit;

/** Pre-Lollipop cookie syncing; CookieManager is always in sync here. */
public final class CookieSyncManager {
    private static final CookieSyncManager INSTANCE = new CookieSyncManager();
    private CookieSyncManager() { }
    public static CookieSyncManager createInstance(android.content.Context context) { return INSTANCE; }
    public static CookieSyncManager getInstance() { return INSTANCE; }
    public void sync() { }
    public void resetSync() { }
    public void startSync() { }
    public void stopSync() { }
}
