package tvbox.runtime;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import org.json.JSONObject;

/**
 * One plugin archive loaded once, as Android TVBox clients do: DEX loading, Init and native
 * guards are shared, and each source only creates its own spider. Loaded in an isolated host
 * class loader per archive, so the static host state below belongs to this archive alone.
 */
public final class SharedPluginRuntime {
    private static final int SOURCE_LIMIT = 24;
    private record Source(PluginSession session, CloudDriveBridge bridge, Path cache) {}
    private final NativeProbe.StandardRuntime runtime;
    private final LinkedHashMap<String, Source> sources = new LinkedHashMap<>(16, 0.75f, true);
    /** Requests in flight per source; a busy source is never evicted. Guarded by this. */
    private final java.util.HashMap<String, Integer> busy = new java.util.HashMap<>();
    /** Spider init stays one at a time, but never under this runtime's lock. */
    private final Object opening = new Object();

    private SharedPluginRuntime(NativeProbe.StandardRuntime runtime) { this.runtime = runtime; }

    public static SharedPluginRuntime open(JSONObject input) throws Exception {
        File jar = new File(input.getString("jar"));
        File cache = new File(input.getString("runtimeCache")); cache.mkdirs();
        HostEnvironment.cache = cache.getAbsolutePath();
        HostEnvironment.converted = input.optString("conversionCache", new File(cache, "converted").getPath());
        HostEnvironment.plugin = jar.getAbsolutePath();
        Path progress = Path.of(input.getString("cache"));
        Files.createDirectories(progress);
        PreparationProgress.begin(progress);
        // Validates guard checksums before any plugin code runs.
        var guards = NativeLibraries.prepareGuards(jar, cache.toPath().resolve("guards"));
        if (!guards.isEmpty()) System.err.println("ANDROID_GUARDS " + guards.keySet());
        long start = System.nanoTime();
        var runtime = NativeProbe.openStandard(jar, cache, new File(cache, "profile"));
        System.err.printf("PLUGIN_RUNTIME_READY %.3fs %s%n", (System.nanoTime() - start) / 1e9, HeapBudget.describe());
        return new SharedPluginRuntime(runtime);
    }

    /**
     * Opening a source (spider init) stays serialized. The request itself only holds its own
     * source, so searches on different sources of this archive run concurrently, as the
     * thread-pool search in Android TVBox clients does. Init can take minutes (network, RSA on
     * the interpreter), so it runs outside this runtime's lock: other searches keep starting
     * and finishing meanwhile.
     */
    public String request(JSONObject input) throws Exception {
        String id = input.getString("session");
        Path cache = Path.of(input.getString("cache"));
        Files.createDirectories(cache);
        PreparationProgress.begin(cache);
        Source source;
        synchronized (this) { source = claim(id); }
        if (source == null) {
            synchronized (opening) {
                synchronized (this) { source = claim(id); }
                if (source == null) {
                    // Make room first: spider init allocates, and a full heap fails it.
                    synchronized (this) { if (HeapBudget.low()) release(false); }
                    Source opened = openSource(input, cache);
                    synchronized (this) {
                        sources.put(id, opened);
                        busy.merge(id, 1, Integer::sum);
                        evict();
                    }
                    source = opened;
                }
            }
        }
        try {
            // A spider keeps per-source state (e.g. the detail loaded before playback).
            synchronized (source) {
                source.bridge().activate();
                try { return source.session().request(input.getJSONObject("params")); }
                finally { CloudDriveBridge.deactivate(); }
            }
        } finally {
            synchronized (this) { busy.computeIfPresent(id, (key, count) -> count > 1 ? count - 1 : null); }
        }
    }

    /** Guarded by this. */
    private Source claim(String id) {
        Source source = sources.get(id);
        if (source != null) busy.merge(id, 1, Integer::sum);
        return source;
    }

    private Source openSource(JSONObject input, Path cache) throws Exception {
        var bridge = new CloudDriveBridge(cache);
        try {
            JSONObject accounts = null;
            if (input.has("cloudAccounts")) {
                var accountPath = Path.of(input.getString("cloudAccounts"));
                if (Files.isRegularFile(accountPath)) accounts = new JSONObject(Files.readString(accountPath));
            }
            input.put("ext", bridge.extension(input.optString("ext"), accounts));
            long start = System.nanoTime();
            var session = NativeProbe.createStandardSession(runtime, input, bridge, accounts);
            System.err.printf("PLUGIN_SOURCE_READY %s %.3fs %s%n", input.optString("key"), (System.nanoTime() - start) / 1e9, HeapBudget.describe());
            return new Source(session, bridge, cache);
        } catch (Throwable failure) {
            bridge.close();
            throw failure;
        }
    }

    /** Guarded by this. */
    private void evict() {
        var iterator = sources.entrySet().iterator();
        while (sources.size() > SOURCE_LIMIT && iterator.hasNext()) {
            var entry = iterator.next();
            Source oldest = entry.getValue();
            if (busy.containsKey(entry.getKey()) || streaming(oldest.cache())) continue;
            iterator.remove();
            try { oldest.session().closeSource(); } catch (Exception error) { error.printStackTrace(System.err); }
        }
    }

    /** Closes every idle spider (the heap ran short or the OS asked for memory); returns how many. */
    public synchronized int trim() { return release(true); }

    /**
     * Closes idle spiders, least recently used first: all of them, or only until the heap has its
     * reserve again. Busy and streaming sources stay. Guarded by this.
     */
    private int release(boolean all) {
        int released = 0;
        var iterator = sources.entrySet().iterator();
        // HeapBudget.low() may run a full collection: check again only after releasing something.
        boolean needed = all || HeapBudget.low();
        while (needed && iterator.hasNext()) {
            var entry = iterator.next();
            if (busy.containsKey(entry.getKey()) || streaming(entry.getValue().cache())) continue;
            iterator.remove(); released++;
            try { entry.getValue().session().closeSource(); } catch (Exception error) { error.printStackTrace(System.err); }
            needed = all || HeapBudget.low();
        }
        return released;
    }

    private static boolean streaming(Path cache) {
        try {
            var activity = cache.resolve("proxy-active");
            return Files.exists(activity) && System.currentTimeMillis() - Files.getLastModifiedTime(activity).toMillis() < 300_000;
        } catch (Exception unreadable) { return false; }
    }

    /** True while any source of this archive served proxy traffic in the last five minutes. */
    public synchronized boolean streaming() {
        return sources.values().stream().anyMatch(source -> streaming(source.cache()));
    }

    public synchronized void close() throws Exception {
        Exception failure = null;
        for (Source source : sources.values()) {
            try { source.session().closeSource(); } catch (Exception error) { failure = error; }
        }
        sources.clear();
        try { android.os.Looper.shutdown(); } catch (Exception error) { failure = error; }
        try { AndroidNativeRuntime.close(); } catch (Exception error) { failure = error; }
        try { runtime.loader().close(); } catch (Exception error) { failure = error; }
        if (failure != null) throw failure;
    }
}
