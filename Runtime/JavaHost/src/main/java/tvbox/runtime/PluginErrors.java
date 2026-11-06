package tvbox.runtime;

import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Exceptions that end a plugin's own threads. A setting often runs on the plugin's executor, so when it fails
 * nothing reaches its caller; the setting's answer reports the error instead of finishing without a word.
 */
public final class PluginErrors {
    private record Failure(long time, Throwable error) { }
    private static final Deque<Failure> recent = new ArrayDeque<>();
    private static boolean installed;
    private PluginErrors() { }

    /** Hears every uncaught exception, still printing it as the JVM does. */
    public static synchronized void install() {
        if (installed) return;
        installed = true;
        Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
            record(error);
            if (previous != null) previous.uncaughtException(thread, error);
            else { System.err.print("Exception in thread \"" + thread.getName() + "\" "); error.printStackTrace(); }
        });
    }
    static synchronized void record(Throwable error) {
        recent.addLast(new Failure(System.currentTimeMillis(), error));
        while (recent.size() > 8) recent.removeFirst();
    }
    /** The first error since `time`, as "Type: message" of its root cause, or null. */
    public static synchronized String since(long time) {
        for (Failure failure : recent) {
            if (failure.time() < time) continue;
            Throwable root = failure.error();
            while (root.getCause() != null && root.getCause() != root) root = root.getCause();
            String message = root.getMessage();
            return root.getClass().getSimpleName() + (message == null || message.isBlank() ? "" : ": " + message);
        }
        return null;
    }
}
