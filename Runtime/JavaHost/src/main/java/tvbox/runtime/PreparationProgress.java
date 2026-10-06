package tvbox.runtime;

import java.nio.charset.StandardCharsets;
import java.nio.file.*;

/**
 * Best-effort, request-local progress. The session class loader isolates static state, and
 * state is per thread because concurrent searches share one runtime: each request publishes to
 * its own file. Threads a plugin starts itself report to the request that began most recently.
 */
public final class PreparationProgress {
    private static final class State {
        final Path file;
        int converted, reused;
        long written;
        String stage = "preparing";
        /** The server a plugin request is waiting on, so the app can say why loading is slow. */
        String host;
        State(Path file) { this.file = file; }
    }
    private static final ThreadLocal<State> current = new ThreadLocal<>();
    private static volatile State latest;
    private PreparationProgress() {}

    private static State state() {
        State state = current.get();
        return state != null ? state : latest;
    }

    public static void begin(Path cache) {
        State state = new State(cache.resolve("preparation-progress.json"));
        current.set(state); latest = state;
        publish(state, "preparing", true, 0, 0);
    }
    // Publish a new conversion immediately, even if it starts within the throttle
    // interval: one class can take a long time on the interpreter.
    public static void converting() { publish(state(), "converting", true, 0, 0); }
    public static void converted(int count) { publish(state(), "loading", false, count, 0); }
    public static void reused(int count) { publish(state(), "reusing", false, 0, count); }
    public static void loading() { publish(state(), "loading", true, 0, 0); }
    /** {@code null} once the request returns. */
    public static void waiting(String host) {
        State state = state();
        if (state == null) return;
        synchronized (state) {
            if (java.util.Objects.equals(state.host, host)) return;
            state.host = host;
        }
        publish(state, null, true, 0, 0);
    }

    private static void publish(State state, String stage, boolean force, int converted, int reused) {
        if (state == null) return;
        synchronized (state) {
            state.converted += converted; state.reused += reused;
            if (stage != null) state.stage = stage;
            long now = System.nanoTime();
            if (!force && state.written != 0 && now - state.written < 250_000_000L) return;
            state.written = now;
            Path temporary = state.file.resolveSibling(state.file.getFileName() + ".tmp");
            try {
                String json = "{\"stage\":\"" + state.stage + "\",\"converted\":" + state.converted + ",\"reused\":" + state.reused
                    + (state.host == null ? "" : ",\"host\":" + org.json.JSONObject.quote(state.host)) + "}";
                Files.writeString(temporary, json, StandardCharsets.UTF_8);
                Files.move(temporary, state.file, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (Exception ignored) {
                // Progress must never change whether a plugin can load.
                try { Files.deleteIfExists(temporary); } catch (Exception cleanupIgnored) { }
            }
        }
    }
}
