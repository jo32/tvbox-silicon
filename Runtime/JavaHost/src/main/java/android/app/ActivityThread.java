package android.app;

/** Context lookup used reflectively by CatVod helpers; no Android activity/UI is emulated. */
public final class ActivityThread {
    private static final ActivityThread CURRENT = new ActivityThread();
    public static ActivityThread currentActivityThread() { return CURRENT; }
    public static Application currentApplication() { return com.github.catvod.spider.Init.application; }
    public Application getApplication() { return currentApplication(); }
}
