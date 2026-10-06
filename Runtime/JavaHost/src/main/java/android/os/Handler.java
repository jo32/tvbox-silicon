package android.os;
import java.util.*;
import java.util.concurrent.*;

public class Handler {
    private final Looper looper;
    private final Map<Runnable, Set<Pending>> pending = new HashMap<>();
    private final class Pending implements Runnable {
        final Runnable action;
        ScheduledFuture<?> future;
        Pending(Runnable action) { this.action = action; }
        @Override public void run() {
            try { action.run(); }
            finally { synchronized (pending) { remove(this); } }
        }
    }
    public Handler() { this(Looper.getMainLooper()); }
    public Handler(Looper looper) { this.looper = looper; }
    public boolean post(Runnable action) { return postDelayed(action, 0); }
    public boolean postDelayed(Runnable action, long delay) {
        Objects.requireNonNull(action);
        synchronized (pending) {
            Pending task = new Pending(action);
            pending.computeIfAbsent(action, key -> new HashSet<>()).add(task);
            try {
                // Scheduling under the same lock ensures a zero-delay callback
                // cannot finish before its future and tracking entry are stored.
                task.future = looper.queue.schedule(task, Math.max(0, delay), TimeUnit.MILLISECONDS);
                return true;
            } catch (RejectedExecutionException closed) { remove(task); return false; }
        }
    }
    private void remove(Pending task) {
        Set<Pending> tasks = pending.get(task.action);
        if (tasks != null) {
            tasks.remove(task);
            if (tasks.isEmpty()) pending.remove(task.action);
        }
    }
    public void removeCallbacks(Runnable action) {
        synchronized (pending) {
            Set<Pending> tasks = pending.remove(action);
            if (tasks != null) for (Pending task : tasks) task.future.cancel(false);
        }
    }
    public Looper getLooper() { return looper; }
}
