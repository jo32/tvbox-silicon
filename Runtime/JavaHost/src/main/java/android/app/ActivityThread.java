package android.app;

/**
 * The app's thread as plugins find it by reflection: {@code sCurrentActivityThread} or
 * {@code currentActivityThread()}, then {@code mActivities} for the record that is not {@code paused}
 * and its {@code activity}, the window their settings dialogs open on (tvbox.runtime.PluginWindows).
 */
public final class ActivityThread {
    private static final ActivityThread CURRENT = new ActivityThread();
    private static ActivityThread sCurrentActivityThread = CURRENT;
    final android.util.ArrayMap<Object, ActivityClientRecord> mActivities = new android.util.ArrayMap<>();
    private Activity activity;

    static final class ActivityClientRecord {
        Activity activity;
        boolean paused;
        boolean stopped;
        ActivityClientRecord(Activity activity) { this.activity = activity; }
    }

    public static ActivityThread currentActivityThread() { return sCurrentActivityThread; }
    public static Application currentApplication() { return com.github.catvod.spider.Init.application; }
    public Application getApplication() { return currentApplication(); }

    /** The one resumed Activity, made once the plugin's Application exists; null before. */
    public synchronized Activity hostActivity() {
        if (activity == null) {
            Application application = currentApplication();
            if (application == null) return null;
            activity = new Activity(application);
            mActivities.put(new Object(), new ActivityClientRecord(activity));
        }
        return activity;
    }
}
