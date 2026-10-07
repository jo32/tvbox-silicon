package tvbox.runtime;

import java.net.URL;
import java.net.URLClassLoader;
import java.lang.reflect.InvocationTargetException;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;

/**
 * JNI entry point. Requests from separate native workers run concurrently; each source still takes
 * one request at a time (its spider keeps detail state for playback). Host classes are isolated
 * per runtime.
 * Sources that share a plugin archive share one runtime (one Init and native guard load), as on
 * Android. FTY-guarded archives use their own loader protocol and keep one runtime per source.
 */
public final class InProcessHost {
    private static final LinkedHashMap<String, Runtime> runtimes = new LinkedHashMap<>(4, 0.75f, true);
    /** Requests share it; closing every runtime waits for them and holds it alone. Fair, so a close is not starved. */
    private static final java.util.concurrent.locks.ReentrantReadWriteLock gate = new java.util.concurrent.locks.ReentrantReadWriteLock(true);
    /** Requests in flight per runtime id; a busy runtime is never closed. Guarded by the class lock. */
    private static final java.util.HashMap<String, Integer> busy = new java.util.HashMap<>();
    /** {@code host} is a SharedPluginRuntime when shared, otherwise a single-source PluginSession. */
    private record Runtime(URLClassLoader loader, Object host, boolean shared, java.nio.file.Path cache) {}
    /**
     * Cancellation flags of requests in flight, by the app's request id. The app sends
     * {@code {"command":"cancel","request":id}} when nobody waits for a request any more; a cancel
     * can arrive before its request does, so either side may create the flag.
     */
    private static final java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicBoolean> cancellations = new java.util.concurrent.ConcurrentHashMap<>();

    public static void closeAll() throws Exception {
        gate.writeLock().lock();
        try { closeAllRuntimes(); } finally { gate.writeLock().unlock(); }
    }

    private static synchronized void closeAllRuntimes() throws Exception {
        Exception failure = null;
        for (Runtime runtime : runtimes.values()) {
            try { close(runtime); } catch (Exception error) { failure = error; }
        }
        runtimes.clear();
        if (failure != null) throw failure;
    }

    private static void close(Runtime runtime) throws Exception {
        try { runtime.host().getClass().getMethod("close").invoke(runtime.host()); }
        finally { runtime.loader().close(); }
    }

    private static boolean streaming(Runtime runtime) throws Exception {
        if (runtime.shared()) return (Boolean) runtime.host().getClass().getMethod("streaming").invoke(runtime.host());
        var activity = runtime.cache().resolve("proxy-active");
        return java.nio.file.Files.exists(activity) && System.currentTimeMillis() - java.nio.file.Files.getLastModifiedTime(activity).toMillis() < 300_000;
    }

    /** When this runtime's media proxy last served traffic, or 0 if it never did. */
    private static long lastStreamed(Runtime runtime) throws Exception {
        if (runtime.shared()) return (Long) runtime.host().getClass().getMethod("lastStreamed").invoke(runtime.host());
        try { return java.nio.file.Files.getLastModifiedTime(runtime.cache().resolve("proxy-active")).toMillis(); }
        catch (java.io.IOException never) { return 0; }
    }

    private static boolean shareable(JSONObject input) {
        if (input.optString("runtime").isEmpty() || input.optString("runtimeCache").isEmpty()) return false;
        try (var zip = new java.util.zip.ZipFile(input.optString("jar"))) {
            return zip.getEntry("assets/ftyguard_v8.so") == null && zip.getEntry("assets/ftyguard-v8.so") == null;
        } catch (java.io.IOException unreadable) { return false; }
    }

    /**
     * {@code {"command":"trim"}} releases idle runtimes and sources (the OS reported memory
     * pressure). {@code {"command":"cancel","request":id}} abandons a request: one still waiting to
     * open its plugin gives up. Any other input is a plugin request.
     */
    public static String request(String inputText) {
        String requestId = "";
        try {
            JSONObject input = new JSONObject(inputText);
            if ("trim".equals(input.optString("command"))) return new JSONObject().put("result", trim("memory pressure", true)).toString();
            if ("cancel".equals(input.optString("command"))) return cancel(input.optString("request"));
            requestId = input.optString("request");
            if (!requestId.isEmpty()) input.put("cancelled", (Object) cancellations.computeIfAbsent(requestId, id -> new java.util.concurrent.atomic.AtomicBoolean()));
            for (int attempt = 1; ; attempt++) {
                try {
                    var lock = gate.readLock();
                    lock.lock();
                    try { return perform(input); } finally { lock.unlock(); }
                } catch (Throwable error) {
                    // The heap is shared by every source. Free what no request is using and try
                    // once more, rather than leaving every later request to fail the same way.
                    if (attempt > 1 || !HeapBudget.outOfMemory(error)) throw error;
                    trim("out of memory", true);
                }
            }
        } catch (java.util.concurrent.CancellationException abandoned) {
            return cancelled();
        } catch (Throwable error) {
            while (error instanceof InvocationTargetException && error.getCause() != null) error = error.getCause();
            // Before a runtime exists (bad input, runtime start-up): the parent loader's classes apply.
            try { return NativeProbe.failure(error).toString(); }
            catch (Exception impossible) { return "{\"error\":\"Plugin request failed\"}"; }
        } finally {
            if (!requestId.isEmpty()) cancellations.remove(requestId);
        }
    }

    private static String cancel(String requestId) {
        if (requestId.isEmpty()) return "{\"result\":false}";
        // A cancel that lost the race with its request's end leaves a set flag behind; keep that bounded.
        if (cancellations.size() > 256) cancellations.values().removeIf(java.util.concurrent.atomic.AtomicBoolean::get);
        cancellations.computeIfAbsent(requestId, id -> new java.util.concurrent.atomic.AtomicBoolean()).set(true);
        System.err.println("PLUGIN_CANCEL " + requestId);
        synchronized (InProcessHost.class) { InProcessHost.class.notifyAll(); }
        return "{\"result\":true}";
    }

    private static String cancelled() {
        return "{\"error\":\"The app no longer needs this request.\",\"errorCode\":\"cancelled\"}";
    }

    private static void checkCancelled(JSONObject input) {
        var flag = OpeningGate.cancelled(input);
        if (flag != null && flag.get()) throw new java.util.concurrent.CancellationException("The app no longer needs this request.");
    }

    /**
     * Runtimes load their own tvbox.runtime classes child-first, so classify the failure with the
     * runtime's NativeProbe (on this thread, for its HttpDiagnostics state), not the parent's copy.
     */
    private static String runtimeFailure(Runtime runtime, Throwable error) {
        while (error instanceof InvocationTargetException && error.getCause() != null) error = error.getCause();
        try {
            return runtime.loader().loadClass("tvbox.runtime.NativeProbe").getMethod("failure", Throwable.class).invoke(null, error).toString();
        } catch (Throwable unavailable) {
            try { return NativeProbe.failure(error).toString(); }
            catch (Exception impossible) { return "{\"error\":\"Plugin request failed\"}"; }
        }
    }

    private static String perform(JSONObject input) throws Throwable {
        boolean shared = shareable(input);
        String id = shared ? "runtime:" + input.getString("runtime") : "session:" + input.getString("session");
        checkCancelled(input);
        Runtime runtime = acquire(id, shared, input);
        try {
            checkCancelled(input);
            ClassLoader previous = Thread.currentThread().getContextClassLoader();
            try {
                Thread.currentThread().setContextClassLoader(runtime.loader());
                Object result;
                try {
                    if (runtime.shared()) {
                        result = runtime.host().getClass().getMethod("request", JSONObject.class).invoke(runtime.host(), input);
                    } else {
                        // A single-source session is one spider; it takes one request at a time.
                        synchronized (runtime.host()) {
                            result = runtime.host().getClass().getMethod("request", JSONObject.class).invoke(runtime.host(), input.getJSONObject("params"));
                        }
                    }
                } catch (Throwable error) {
                    if (HeapBudget.outOfMemory(error)) throw new OutOfMemoryError("Java heap space");
                    Throwable cause = error;
                    while (cause instanceof InvocationTargetException && cause.getCause() != null) cause = cause.getCause();
                    if (cause instanceof java.util.concurrent.CancellationException) return cancelled();
                    return runtimeFailure(runtime, error);
                }
                return new JSONObject().put("result", result).toString();
            } finally { Thread.currentThread().setContextClassLoader(previous); }
        } finally { release(id); }
    }

    private static synchronized void release(String id) {
        busy.computeIfPresent(id, (key, count) -> count > 1 ? count - 1 : null);
        InProcessHost.class.notifyAll();
    }

    /** Serializes runtime start-up without holding the class lock, which every finishing request needs. */
    private static final OpeningGate opening = new OpeningGate();

    /** Finds or opens a runtime and marks it busy. */
    private static Runtime acquire(String id, boolean shared, JSONObject input) throws Throwable {
        synchronized (InProcessHost.class) {
            Runtime runtime = claim(id);
            if (runtime != null) return runtime;
        }
        // Start-up (DEX indexing, Init, native guards) can take minutes on first use. Only other
        // openers wait for it; searches on open runtimes keep starting and returning. The viewer's
        // own requests open before waiting searches, and an abandoned request stops waiting.
        opening.enter(OpeningGate.search(input), OpeningGate.cancelled(input));
        try {
            synchronized (InProcessHost.class) {
                Runtime runtime = claim(id);
                if (runtime != null) return runtime;
                makeRoom(input);
            }
            checkCancelled(input);
            Runtime runtime = open(shared, input);
            synchronized (InProcessHost.class) {
                runtimes.put(id, runtime);
                busy.merge(id, 1, Integer::sum);
                return runtime;
            }
        } finally { opening.leave(); }
    }

    /** Guarded by the class lock. */
    private static Runtime claim(String id) {
        Runtime runtime = runtimes.get(id);
        if (runtime != null) busy.merge(id, 1, Integer::sum);
        return runtime;
    }

    /**
     * Frees a slot for one more runtime: at most two stay open, fewer while the heap is short.
     * Guarded by the class lock; only an opener calls it.
     */
    private static void makeRoom(JSONObject input) throws Exception {
        if (!runtimes.isEmpty() && HeapBudget.low()) trimLocked("opening another plugin", false);
        while (runtimes.size() >= 2) {
            var iterator = runtimes.entrySet().iterator();
            boolean waiting = false;
            while (iterator.hasNext()) {
                var entry = iterator.next();
                if (busy.containsKey(entry.getKey())) { waiting = true; continue; }
                if (streaming(entry.getValue())) continue;
                close(entry.getValue()); iterator.remove(); return;
            }
            if (!waiting) {
                // Both proxies served media lately, but the app plays one stream at a time: the source
                // streamed most recently is the one playing. Release the other instead of refusing the
                // source the viewer just chose (trying a second source after one fails is common).
                Map.Entry<String, Runtime> stale = null;
                for (var entry : runtimes.entrySet()) {
                    if (stale == null || lastStreamed(entry.getValue()) < lastStreamed(stale.getValue())) stale = entry;
                }
                close(stale.getValue()); runtimes.remove(stale.getKey()); return;
            }
            // Both slots are serving other searches; wait for one to finish rather than fail.
            checkCancelled(input);
            InProcessHost.class.wait(250);
        }
    }

    private static synchronized String trim(String reason, boolean everything) {
        return trimLocked(reason, everything);
    }

    /**
     * Releases what no request is using, least recently used first: idle spiders of each
     * archive, then whole idle runtimes. Without {@code everything} it stops once the heap has
     * its reserve again. After an OutOfMemoryError or an OS memory warning it releases all of
     * it: a runtime that ran out of memory mid-initialization may be left broken. Anything
     * serving a request or a playback proxy stays. Guarded by the class lock.
     */
    private static String trimLocked(String reason, boolean everything) {
        String before = HeapBudget.describe();
        int sources = 0, closed = 0;
        for (var entry : runtimes.entrySet()) {
            if (!entry.getValue().shared()) continue;
            try { sources += (Integer) entry.getValue().host().getClass().getMethod("trim").invoke(entry.getValue().host()); }
            catch (Exception error) { error.printStackTrace(System.err); }
            if (!everything && !HeapBudget.low()) break;
        }
        var iterator = runtimes.entrySet().iterator();
        // HeapBudget.low() may run a full collection: check again only after closing something.
        boolean needed = everything || HeapBudget.low();
        while (needed && iterator.hasNext()) {
            var entry = iterator.next();
            try {
                if (busy.containsKey(entry.getKey()) || streaming(entry.getValue())) continue;
                iterator.remove(); closed++;
                close(entry.getValue());
            } catch (Exception error) { error.printStackTrace(System.err); }
            needed = everything || HeapBudget.low();
        }
        // Collected heap is also returned to the OS (MaxHeapFreeRatio), which memory pressure needs.
        if (everything) System.gc();
        String summary = "released " + sources + " sources and " + closed + " runtimes (" + reason + "): " + before + " -> " + HeapBudget.describe();
        System.err.println("HEAP_TRIM " + summary);
        return summary;
    }

    private static Runtime open(boolean shared, JSONObject input) throws Throwable {
        URL host = InProcessHost.class.getProtectionDomain().getCodeSource().getLocation();
        URL androidClass = InProcessHost.class.getClassLoader().getResource("android/app/Activity.class");
        URL androidJar = ((java.net.JarURLConnection) androidClass.openConnection()).getJarFileURL();
        var loader = new URLClassLoader(new URL[]{host, androidJar}, InProcessHost.class.getClassLoader()) {
            @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                synchronized (getClassLoadingLock(name)) {
                    Class<?> found = findLoadedClass(name);
                    if (found == null && (name.startsWith("tvbox.runtime.") || name.startsWith("android.") || name.startsWith("dalvik.") || name.startsWith("com.github.catvod."))) {
                        try { found = findClass(name); } catch (ClassNotFoundException absent) { }
                    }
                    if (found == null) found = super.loadClass(name, false);
                    if (resolve) resolveClass(found);
                    return found;
                }
            }
        };
        ClassLoader previous = Thread.currentThread().getContextClassLoader();
        try {
            Thread.currentThread().setContextClassLoader(loader);
            Object value = shared
                ? loader.loadClass("tvbox.runtime.SharedPluginRuntime").getMethod("open", JSONObject.class).invoke(null, input)
                : loader.loadClass("tvbox.runtime.NativeProbe").getMethod("initialize", JSONObject.class).invoke(null, input);
            return new Runtime(loader, value, shared, java.nio.file.Path.of(input.getString("cache")));
        } catch (Throwable failure) {
            try { loader.loadClass("android.os.Looper").getMethod("shutdown").invoke(null); } catch (Throwable cleanup) { failure.addSuppressed(cleanup); }
            try { loader.loadClass("tvbox.runtime.CloudDriveBridge").getMethod("closeCurrent").invoke(null); } catch (Throwable cleanup) { failure.addSuppressed(cleanup); }
            try { loader.loadClass("tvbox.runtime.AndroidNativeRuntime").getMethod("close").invoke(null); } catch (Throwable cleanup) { failure.addSuppressed(cleanup); }
            loader.close(); throw failure;
        }
        finally { Thread.currentThread().setContextClassLoader(previous); }
    }
}
