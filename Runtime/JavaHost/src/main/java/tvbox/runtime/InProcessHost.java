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
    /** Requests in flight per runtime; a busy runtime is never closed. Guarded by the class lock. */
    private static final java.util.IdentityHashMap<Runtime, Integer> busy = new java.util.IdentityHashMap<>();
    /**
     * Runtimes taken out of service while a request in them would not end (see OpeningGate.Stuck).
     * Each closes once that request returns. Guarded by the class lock.
     */
    private static final java.util.Set<Runtime> retired = java.util.Collections.newSetFromMap(new java.util.IdentityHashMap<>());
    /** {@code host} is a SharedPluginRuntime when shared, otherwise a single-source PluginSession. */
    private record Runtime(URLClassLoader loader, Object host, boolean shared, java.nio.file.Path cache, OpeningGate requests) {}
    /**
     * Stop times of requests in flight, by the app's request id (see OpeningGate). The app sends
     * {@code {"command":"cancel","request":id}} when nobody waits for a request any more; a cancel
     * can arrive before its request does, so either side may create the entry.
     */
    private static final java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicLong> cancellations = new java.util.concurrent.ConcurrentHashMap<>();

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
        boolean counted = false;
        try {
            JSONObject input = new JSONObject(inputText);
            if ("recoverProxy".equals(input.optString("command"))) return recoverProxy(input.getString("url"));
            if ("directMedia".equals(input.optString("command"))) return directMedia(input.getString("url"));
            if ("trim".equals(input.optString("command"))) { ConvertAhead.release(); return new JSONObject().put("result", trim("memory pressure", true)).toString(); }
            if ("cancel".equals(input.optString("command"))) return cancel(input.optString("request"));
            // Background work: it yields to every plugin request (see ConvertAhead).
            if ("convertAhead".equals(input.optString("command"))) return convertAhead(input);
            requestId = input.optString("request");
            inFlight.incrementAndGet();
            counted = true;
            var stopAt = requestId.isEmpty() ? new java.util.concurrent.atomic.AtomicLong()
                : cancellations.computeIfAbsent(requestId, id -> new java.util.concurrent.atomic.AtomicLong());
            input.put("stopAt", (Object) stopAt);
            // The spider sees its stop time and deadline through its own parameters.
            var params = input.optJSONObject("params");
            if (params != null) {
                params.put("_stopAt", (Object) stopAt);
                // A Baidu or Aliyun sign-in code goes to this source's session folder (LoginPrompt).
                if (input.has("cache")) params.put("_folder", input.optString("cache"));
                if (input.has("deadline")) params.put("_deadline", input.optLong("deadline"));
            }
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
            if (counted) inFlight.decrementAndGet();
            if (!requestId.isEmpty()) cancellations.remove(requestId);
        }
    }

    /** Plugin requests in this JVM right now, including ones waiting to open their plugin. */
    private static final java.util.concurrent.atomic.AtomicInteger inFlight = new java.util.concurrent.atomic.AtomicInteger();

    /**
     * {@code {"command":"convertAhead",…}}: see ConvertAhead. It stops while a plugin request runs or a
     * plugin's proxy is serving media (the viewer is watching), so it never competes with either.
     */
    private static String convertAhead(JSONObject input) throws Exception {
        if ("release".equals(input.optString("action"))) { ConvertAhead.release(); return "{\"result\":true}"; }
        try { return new JSONObject().put("result", ConvertAhead.run(input, () -> inFlight.get() > 0 || streamingAny())).toString(); }
        catch (OutOfMemoryError exhausted) { ConvertAhead.release(); trim("out of memory", true); throw exhausted; }
    }

    private static synchronized boolean streamingAny() {
        for (Runtime runtime : runtimes.values()) if (streamingQuietly(runtime)) return true;
        return false;
    }

    private static String cancel(String requestId) {
        if (requestId.isEmpty()) return "{\"result\":false}";
        long now = System.currentTimeMillis();
        // A cancel that lost the race with its request's end leaves an entry behind; keep that bounded.
        if (cancellations.size() > 256) cancellations.values().removeIf(stop -> stop.get() > 0 && stop.get() < now - 60_000);
        cancellations.computeIfAbsent(requestId, id -> new java.util.concurrent.atomic.AtomicLong())
            .accumulateAndGet(now, (current, next) -> current == 0 ? next : Math.min(current, next));
        System.err.println("PLUGIN_CANCEL " + requestId);
        synchronized (InProcessHost.class) { InProcessHost.class.notifyAll(); }
        return "{\"result\":true}";
    }

    private static String recoverProxy(String address) throws Exception {
        gate.readLock().lock();
        try {
            synchronized (InProcessHost.class) {
                for (Runtime runtime : runtimes.values()) {
                    String recovered = (String)runtime.host().getClass().getMethod("recoverProxy", String.class).invoke(runtime.host(), address);
                    if (recovered != null) return new JSONObject().put("result", recovered).toString();
                }
            }
            return new JSONObject().put("result", address).toString();
        } finally { gate.readLock().unlock(); }
    }

    /** {@code {"command":"directMedia","url":…}}: the CDN request behind a cloud-drive proxy address. */
    private static String directMedia(String address) throws Exception {
        gate.readLock().lock();
        try {
            java.util.List<Object> hosts;
            synchronized (InProcessHost.class) { hosts = runtimes.values().stream().map(Runtime::host).toList(); }
            for (Object host : hosts) {
                Object media = host.getClass().getMethod("directMedia", String.class).invoke(host, address);
                if (media != null) return new JSONObject().put("result", new JSONObject((String) media)).toString();
            }
            return new JSONObject().put("result", JSONObject.NULL).toString();
        } finally { gate.readLock().unlock(); }
    }

    private static String cancelled() {
        return "{\"error\":\"The app no longer needs this request.\",\"errorCode\":\"cancelled\"}";
    }

    private static void checkCancelled(JSONObject input) {
        if (OpeningGate.stopped(OpeningGate.cancelled(input))) throw new java.util.concurrent.CancellationException("The app no longer needs this request.");
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
        for (int attempt = 1; ; attempt++) {
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
                            runtime.requests().enter(OpeningGate.search(input), OpeningGate.cancelled(input));
                            try {
                                // A warm FTY session runs on a new worker thread. Start progress in
                                // its own class loader on every request, not only during plugin init.
                                runtime.loader().loadClass("tvbox.runtime.PreparationProgress")
                                    .getMethod("begin", java.nio.file.Path.class).invoke(null, runtime.cache());
                                result = runtime.host().getClass().getMethod("request", JSONObject.class).invoke(runtime.host(), input.getJSONObject("params"));
                            } finally { runtime.requests().leave(); }
                        }
                    } catch (Throwable error) {
                        if (HeapBudget.outOfMemory(error)) throw new OutOfMemoryError("Java heap space");
                        Throwable cause = error;
                        while (cause instanceof InvocationTargetException && cause.getCause() != null) cause = cause.getCause();
                        if (cause instanceof java.util.concurrent.CancellationException) return cancelled();
                        // An earlier request is still running in this spider long after it was told to
                        // stop. Take the runtime out of service and serve this request from a fresh one.
                        if (cause instanceof OpeningGate.Stuck && attempt == 1) { retire(id, runtime); continue; }
                        // The plugin's own sign-in completed, but only a fresh spider reads the saved account.
                        if (attempt == 1 && signedIn(cause)) { retire(id, runtime); OpeningGate.freshDeadline(input); continue; }
                        return runtimeFailure(runtime, error);
                    }
                    return new JSONObject().put("result", result).toString();
                } finally { Thread.currentThread().setContextClassLoader(previous); }
            } finally { release(runtime); }
        }
    }

    private static void release(Runtime runtime) {
        boolean close;
        synchronized (InProcessHost.class) {
            busy.computeIfPresent(runtime, (key, count) -> count > 1 ? count - 1 : null);
            // A retired runtime closes once its last request returns, unless it still serves a stream.
            close = !busy.containsKey(runtime) && retired.contains(runtime) && !streamingQuietly(runtime);
            if (close) retired.remove(runtime);
            InProcessHost.class.notifyAll();
        }
        if (close) {
            try { close(runtime); } catch (Exception error) { error.printStackTrace(System.err); }
            System.err.println("PLUGIN_RUNTIME_CLOSED retired");
        }
    }

    private static void retire(String id, Runtime runtime) {
        synchronized (InProcessHost.class) {
            runtime.requests().retire();
            if (runtimes.get(id) == runtime) runtimes.remove(id);
            retired.add(runtime);
        }
        System.err.println("PLUGIN_RUNTIME_RETIRED " + java.time.LocalTime.now().withNano(0) + " " + id);
    }

    /** HttpDiagnostics.SignedIn from the runtime's own class loader. */
    static boolean signedIn(Throwable cause) {
        return cause != null && cause.getClass().getName().equals("tvbox.runtime.HttpDiagnostics$SignedIn");
    }

    private static boolean streamingQuietly(Runtime runtime) {
        try { return streaming(runtime); } catch (Exception unreadable) { return false; }
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
                busy.merge(runtime, 1, Integer::sum);
                return runtime;
            }
        } finally { opening.leave(); }
    }

    /** Guarded by the class lock. */
    private static Runtime claim(String id) {
        Runtime runtime = runtimes.get(id);
        if (runtime != null) busy.merge(runtime, 1, Integer::sum);
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
                Runtime candidate = entry.getValue();
                if (busy.containsKey(candidate)) {
                    // A request that will not end must not hold a slot other sources need.
                    if (candidate.requests().stuck()) {
                        candidate.requests().retire(); retired.add(candidate); iterator.remove();
                        System.err.println("PLUGIN_RUNTIME_RETIRED " + java.time.LocalTime.now().withNano(0) + " " + entry.getKey() + " (slot)");
                        return;
                    }
                    waiting = true; continue;
                }
                if (streaming(candidate)) continue;
                close(candidate); iterator.remove(); return;
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
                if (busy.containsKey(entry.getValue()) || streaming(entry.getValue())) continue;
                iterator.remove(); closed++;
                close(entry.getValue());
            } catch (Exception error) { error.printStackTrace(System.err); }
            needed = everything || HeapBudget.low();
        }
        // Retired runtimes whose stuck request has returned but which were still streaming then.
        for (var stale = retired.iterator(); stale.hasNext(); ) {
            Runtime runtime = stale.next();
            if (busy.containsKey(runtime) || streamingQuietly(runtime)) continue;
            stale.remove(); closed++;
            try { close(runtime); } catch (Exception error) { error.printStackTrace(System.err); }
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
            return new Runtime(loader, value, shared, java.nio.file.Path.of(input.getString("cache")), new OpeningGate(true));
        } catch (Throwable failure) {
            try { loader.loadClass("android.os.Looper").getMethod("shutdown").invoke(null); } catch (Throwable cleanup) { failure.addSuppressed(cleanup); }
            try { loader.loadClass("tvbox.runtime.CloudDriveBridge").getMethod("closeCurrent").invoke(null); } catch (Throwable cleanup) { failure.addSuppressed(cleanup); }
            try { loader.loadClass("tvbox.runtime.AndroidNativeRuntime").getMethod("close").invoke(null); } catch (Throwable cleanup) { failure.addSuppressed(cleanup); }
            loader.close(); throw failure;
        }
        finally { Thread.currentThread().setContextClassLoader(previous); }
    }
}
