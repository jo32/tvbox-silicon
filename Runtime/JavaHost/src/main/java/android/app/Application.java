package android.app;
import android.content.ContextWrapper;
import java.io.File;
public class Application extends ContextWrapper {
    public Application(File root, ClassLoader loader) { super(root, loader); }
    private final java.util.Set<ActivityLifecycleCallbacks> callbacks = new java.util.concurrent.CopyOnWriteArraySet<>();
    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) { callbacks.add(callback); }
    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) { callbacks.remove(callback); }
    public interface ActivityLifecycleCallbacks {
        void onActivityCreated(Activity activity, android.os.Bundle state);
        void onActivityStarted(Activity activity);
        void onActivityResumed(Activity activity);
        void onActivityPaused(Activity activity);
        void onActivityStopped(Activity activity);
        void onActivitySaveInstanceState(Activity activity, android.os.Bundle state);
        void onActivityDestroyed(Activity activity);
    }
}
