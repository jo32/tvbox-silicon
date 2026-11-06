package android.os;
import java.util.concurrent.*;
public final class Looper {
    private static final Looper MAIN = new Looper();
    private volatile Thread thread;
    final ScheduledThreadPoolExecutor queue = new ScheduledThreadPoolExecutor(1, r -> {
        Thread t = new Thread(r, "plugin-main"); t.setDaemon(true); thread = t; return t;
    });
    private Looper() {
        queue.setRemoveOnCancelPolicy(true);
        queue.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
        queue.setContinueExistingPeriodicTasksAfterShutdownPolicy(false);
    }
    /** Dispose only the host-owned callback queue when this source is evicted. */
    public static void shutdown() { MAIN.queue.shutdownNow(); }
    public static Looper getMainLooper() { return MAIN; }
    public boolean isCurrentThread() { return Thread.currentThread() == thread; }
    public Thread getThread() { return thread; }
    public static Looper myLooper() { return MAIN; }
}
