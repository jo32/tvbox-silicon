package tvbox.runtime;

import java.net.URL;
import java.net.URLClassLoader;
import java.lang.reflect.InvocationTargetException;
import java.util.LinkedHashMap;
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

    private static boolean shareable(JSONObject input) {
        if (input.optString("runtime").isEmpty() || input.optString("runtimeCache").isEmpty()) return false;
        try (var zip = new java.util.zip.ZipFile(input.optString("jar"))) {
            return zip.getEntry("assets/ftyguard_v8.so") == null && zip.getEntry("assets/ftyguard-v8.so") == null;
        } catch (java.io.IOException unreadable) { return false; }
    }

    public static String request(String inputText) {
        try {
            JSONObject input = new JSONObject(inputText);
            var lock = gate.readLock();
            lock.lock();
            try { return perform(input); } finally { lock.unlock(); }
        } catch (Throwable error) {
            while (error instanceof InvocationTargetException && error.getCause() != null) error = error.getCause();
            // Before a runtime exists (bad input, runtime start-up): the parent loader's classes apply.
            try { return NativeProbe.failure(error).toString(); }
            catch (Exception impossible) { return "{\"error\":\"Plugin request failed\"}"; }
        }
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
        Runtime runtime = acquire(id, shared, input);
        try {
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
    private static final Object opening = new Object();

    /** Finds or opens a runtime and marks it busy. */
    private static Runtime acquire(String id, boolean shared, JSONObject input) throws Throwable {
        synchronized (InProcessHost.class) {
            Runtime runtime = claim(id);
            if (runtime != null) return runtime;
        }
        // Start-up (DEX indexing, Init, native guards) can take minutes on first use. Only other
        // openers wait for it; searches on open runtimes keep starting and returning.
        synchronized (opening) {
            synchronized (InProcessHost.class) {
                Runtime runtime = claim(id);
                if (runtime != null) return runtime;
                makeRoom();
            }
            Runtime runtime = open(shared, input);
            synchronized (InProcessHost.class) {
                runtimes.put(id, runtime);
                busy.merge(id, 1, Integer::sum);
                return runtime;
            }
        }
    }

    /** Guarded by the class lock. */
    private static Runtime claim(String id) {
        Runtime runtime = runtimes.get(id);
        if (runtime != null) busy.merge(id, 1, Integer::sum);
        return runtime;
    }

    /** Frees a slot for one more runtime. Guarded by the class lock; only an opener calls it. */
    private static void makeRoom() throws Exception {
        while (runtimes.size() >= 2) {
            var iterator = runtimes.entrySet().iterator();
            boolean waiting = false;
            while (iterator.hasNext()) {
                var entry = iterator.next();
                if (busy.containsKey(entry.getKey())) { waiting = true; continue; }
                if (streaming(entry.getValue())) continue;
                close(entry.getValue()); iterator.remove(); return;
            }
            if (!waiting) throw new IllegalStateException("Both plugin sources are streaming. Stop playback before opening another source.");
            // Both slots are serving other searches; wait for one to finish rather than fail.
            InProcessHost.class.wait();
        }
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
