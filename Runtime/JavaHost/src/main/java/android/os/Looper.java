package android.os;
import java.util.concurrent.*;
public final class Looper {
    private static final Looper MAIN = new Looper();
    final ScheduledThreadPoolExecutor queue = new ScheduledThreadPoolExecutor(1, r -> {
        Thread t = new Thread(r, "plugin-main"); t.setDaemon(true); return t;
    });
    private Looper() {
        queue.setRemoveOnCancelPolicy(true);
        queue.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
        queue.setContinueExistingPeriodicTasksAfterShutdownPolicy(false);
    }
    /** Dispose only the host-owned callback queue when this source is evicted. */
    public static void shutdown() { MAIN.queue.shutdownNow(); }
    public static Looper getMainLooper() { return MAIN; }
    public static Looper myLooper() { return MAIN; }
}
