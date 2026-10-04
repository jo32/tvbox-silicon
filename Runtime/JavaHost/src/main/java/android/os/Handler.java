package android.os;
import java.util.*;
import java.util.concurrent.*;
public class Handler {
    private final Looper looper;
    private final Map<Runnable,List<ScheduledFuture<?>>> pending = new ConcurrentHashMap<>();
    public Handler() { this(Looper.getMainLooper()); }
    public Handler(Looper looper) { this.looper = looper; }
    public boolean post(Runnable action) { return postDelayed(action, 0); }
    public boolean postDelayed(Runnable action, long delay) {
        pending.computeIfAbsent(action, key -> new CopyOnWriteArrayList<>()).add(looper.queue.schedule(action, Math.max(0,delay), TimeUnit.MILLISECONDS));
        return true;
    }
    public void removeCallbacks(Runnable action) {
        List<ScheduledFuture<?>> tasks = pending.remove(action);
        if (tasks != null) tasks.forEach(task -> task.cancel(false));
    }
    public Looper getLooper() { return looper; }
}
