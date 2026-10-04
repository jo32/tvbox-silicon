package android.os;
import java.util.concurrent.*;
public final class Looper {
    private static final Looper MAIN = new Looper();
    final ScheduledExecutorService queue = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "plugin-main"); t.setDaemon(true); return t;
    });
    public static Looper getMainLooper() { return MAIN; }
    public static Looper myLooper() { return MAIN; }
}
