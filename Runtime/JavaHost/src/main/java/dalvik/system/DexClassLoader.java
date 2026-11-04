package dalvik.system;
import com.googlecode.d2j.dex.Dex2jar;
import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.jar.JarFile;
/** Converts loaded DEX to JVM bytecode while retaining the plugin's own classes. */
public class DexClassLoader extends URLClassLoader {
    public static DexClassLoader current;
    /** Every plugin DEX loader, oldest first. A plugin can open several (its spiders, then a helper
     *  such as tink-dex.jar); `current` is only the newest one. */
    private static final java.util.List<java.lang.ref.WeakReference<DexClassLoader>> loaders = new java.util.concurrent.CopyOnWriteArrayList<>();

    /**
     * The class `name` from whichever plugin DEX defines it, for native code that names classes
     * without a loader (JNI FindClass/NewObject). Asking only `current` broke every spider created
     * after a plugin opened a second DEX: the aowu loader opens tink-dex.jar, and then the native
     * getSpider could no longer find TStzg, KuGou, Wgdj... Newest loader first, own classes only,
     * so a later DEX's placeholder never hides the real class; then `current` as before.
     */
    public static Class<?> pluginClass(String name) {
        for (int i = loaders.size() - 1; i >= 0; i--) {
            DexClassLoader loader = loaders.get(i).get();
            if (loader == null) continue;
            try { return loader.ownLoadedOrDefined(name); }
            catch (ClassNotFoundException absent) { }
        }
        if (current == null) return null;
        try { return Class.forName(name, false, current); }
        catch (ClassNotFoundException missing) { return null; }
    }

    /** Classes guest code got from a plugin loader's loadClass, by name; see {@link #guestClass}. */
    private static final java.util.Map<String, java.lang.ref.WeakReference<Class<?>>> handedToGuest = new java.util.concurrent.ConcurrentHashMap<>();
    private static final StackWalker WALKER = StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE);

    /**
     * The class a plugin loader last gave guest native code under this name. unidbg turns a Class that
     * JNI receives into a class name, so `loader.loadClass("...Proxy")` followed by GetStaticMethodID
     * resolved "Proxy" again by name, which found the outer archive's stub instead of the inner DEX's
     * class. The aowu proxyInvoke then called itself ("IllegalStateException: running") and every
     * proxied stream (韩剧, 秋天, 经典, 魔都, 爱看) answered 502. Class name mappers ask this first.
     */
    public static Class<?> guestClass(String name) {
        var reference = handedToGuest.get(name);
        return reference == null ? null : reference.get();
    }

    /**
     * A DEX the plugin opens itself gets `context.getClassLoader()` as parent. On Android that is the app's
     * loader; here it is the plugin's own archive, whose same-named spider classes (the aowu jar's Proxy,
     * Init, Danmaku stubs) would win parent-first. Like PluginClassLoader, a DEX's own spider classes come
     * first; the shared crawler API still comes from the host.
     */
    @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
        if (name.startsWith("com.github.catvod.") && !name.startsWith("com.github.catvod.crawler.")) {
            synchronized (getClassLoadingLock(name)) {
                Class<?> loaded = findLoadedClass(name);
                if (loaded == null) {
                    try { loaded = findOwnClass(name); } catch (ClassNotFoundException inherited) { }
                }
                if (loaded != null) {
                    if (resolve) resolveClass(loaded);
                    return loaded;
                }
            }
        }
        return super.loadClass(name, resolve);
    }

    @Override public Class<?> loadClass(String name) throws ClassNotFoundException {
        Class<?> loaded = super.loadClass(name);
        if (loaded.getClassLoader() instanceof DexClassLoader && calledByGuest()) handedToGuest.put(name, new java.lang.ref.WeakReference<>(loaded));
        return loaded;
    }

    /** Whether the first caller outside reflection and class loading is unidbg's JNI bridge (guest code). */
    private static boolean calledByGuest() {
        return WALKER.walk(frames -> frames.skip(1)
            .filter(frame -> !ClassLoader.class.isAssignableFrom(frame.getDeclaringClass()) && frame.getDeclaringClass() != Class.class
                && !frame.getClassName().startsWith("java.lang.reflect.") && !frame.getClassName().startsWith("jdk.internal.reflect.")
                && !frame.getClassName().startsWith("java.lang.invoke."))
            .findFirst().map(frame -> frame.getClassName().startsWith("com.github.unidbg.")).orElse(false));
    }

    private Class<?> ownLoadedOrDefined(String name) throws ClassNotFoundException {
        synchronized (getClassLoadingLock(name)) {
            Class<?> loaded = findLoadedClass(name);
            return loaded != null ? loaded : findPluginClass(name);
        }
    }
    private tvbox.runtime.LazyDexArchive lazy;
    private final java.util.Map<String, Path> preparedClasses = new java.util.HashMap<>();
    private final Path archive;
    private tvbox.runtime.DanglingTypes dangling;
    public DexClassLoader(String path, String optimizedDirectory, String librarySearchPath, ClassLoader parent) throws Exception {
        this(tvbox.runtime.AndroidNativeRuntime.hostPath(path), optimizedDirectory, parent);
    }
    private DexClassLoader(String path, String optimizedDirectory, ClassLoader parent) throws Exception {
        super(Boolean.getBoolean("tvbox.apple") || Boolean.getBoolean("tvbox.lazyDex")
            ? new URL[]{new File(path).toURI().toURL()}
            : new URL[]{convert(path, optimizedDirectory), new File(path).toURI().toURL()}, parent);
        if (Boolean.getBoolean("tvbox.apple") || Boolean.getBoolean("tvbox.lazyDex")) {
            boolean dex = true;
            if (path.endsWith(".jar") || new File(path).isFile()) {
                try (var archive = new JarFile(path)) {
                    dex = archive.stream().anyMatch(e -> e.getName().matches("classes[0-9]*\\.dex"));
                } catch (java.util.zip.ZipException rawDex) { }
            }
            if (dex) lazy = new tvbox.runtime.LazyDexArchive(path, optimizedDirectory);
        }
        archive = Path.of(path);
        current = this;
        loaders.removeIf(reference -> reference.get() == null);
        loaders.add(new java.lang.ref.WeakReference<>(this));
        System.err.println("DEX_LOADER_READY " + path);
    }
    @Override protected Class<?> findClass(String name) throws ClassNotFoundException {
        try { return findPluginClass(name); }
        catch (ClassNotFoundException missing) {
            synchronized (this) { if (dangling == null) dangling = tvbox.runtime.DanglingTypes.of(archive); }
            if (!dangling.contains(name)) throw missing;
            System.err.println("DEX_PLACEHOLDER " + name);
            byte[] bytes = dangling.placeholder(name);
            return defineClass(name, bytes, 0, bytes.length);
        }
    }
    /** A class the plugin's own archive defines: never a placeholder, never the parent's. */
    protected Class<?> findOwnClass(String name) throws ClassNotFoundException { return findPluginClass(name); }
    private Class<?> findPluginClass(String name) throws ClassNotFoundException {
        // URLClassLoader otherwise scans every previously converted class JAR on
        // each miss. For N lazy classes that is quadratic archive lookup work.
        Path prepared = preparedClasses.get(name);
        if (prepared == null && (lazy == null || !lazy.contains(name))) return super.findClass(name);
        try {
            if (prepared == null) {
                prepared = lazy.prepare(name);
                // Keep URL resource lookup behavior, but index all emitted helper
                // classes so defining them does not scan the growing URL list.
                addURL(prepared.toUri().toURL());
                try (var archive = new JarFile(prepared.toFile())) {
                    var entries = archive.entries();
                    while (entries.hasMoreElements()) {
                        String entry = entries.nextElement().getName();
                        if (entry.endsWith(".class")) preparedClasses.put(entry.substring(0, entry.length() - 6).replace('/', '.'), prepared);
                    }
                }
            }
            byte[] bytes;
            try (var archive = new JarFile(prepared.toFile())) {
                var entry = archive.getJarEntry(name.replace('.', '/') + ".class");
                if (entry == null) throw new ClassNotFoundException(name);
                try (var input = archive.getInputStream(entry)) { bytes = input.readAllBytes(); }
            }
            int separator = name.lastIndexOf('.');
            if (separator > 0) {
                String packageName = name.substring(0, separator);
                if (getDefinedPackage(packageName) == null) definePackage(packageName, null, null, null, null, null, null, null);
            }
            return defineClass(name, bytes, 0, bytes.length,
                new java.security.CodeSource(prepared.toUri().toURL(), (java.security.cert.Certificate[]) null));
        } catch (ClassNotFoundException error) { throw error; }
        catch (Exception error) {
            // Plugins usually swallow this; the JVM then reports only NoClassDefFoundError.
            System.err.println("DEX_CLASS_FAILED " + name + " thread=" + Thread.currentThread().getName());
            error.printStackTrace(System.err);
            throw new ClassNotFoundException("Cannot prepare " + name, error);
        }
    }
    private static synchronized URL convert(String path, String cache) throws Exception {
        byte[] data = Files.readAllBytes(new File(path).toPath());
        String hash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        File fallback = new File(tvbox.runtime.HostEnvironment.cache(cache), "converted");
        Path folder = Path.of(tvbox.runtime.HostEnvironment.converted(fallback.getPath()));
        Files.createDirectories(folder);
        // Both the DEX content and host transform version determine the artifact.
        // A process lock prevents concurrent searches from converting the same DEX.
        String key = hash + "." + tvbox.runtime.BytecodeCompatibility.VERSION;
        Path compatible = folder.resolve(key + ".jar");
        try (FileChannel channel = FileChannel.open(folder.resolve(key + ".lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             var lock = channel.lock()) {
            if (valid(compatible)) {
                tvbox.runtime.PreparationProgress.reused(classCount(compatible));
                System.err.println("DEX_CACHE_HIT " + key);
                return compatible.toUri().toURL();
            }
            tvbox.runtime.PreparationProgress.converting();
            Path original = Files.createTempFile(folder, "dex-", ".jar");
            Path rewritten = Files.createTempFile(folder, "rewritten-", ".jar");
            try {
                boolean jvmArchive = false;
                if (data.length > 2 && data[0] == 'P' && data[1] == 'K') {
                    try (var archive = new JarFile(path)) {
                        jvmArchive = archive.stream().noneMatch(e -> e.getName().matches("classes[0-9]*\\.dex"))
                            && archive.stream().anyMatch(e -> e.getName().endsWith(".class"));
                    }
                }
                if (jvmArchive) Files.write(original, data);
                else Dex2jar.from(com.googlecode.d2j.reader.MultiDexFileReader.open(data)).skipDebug(true).computeFrames(true).to(original);
                tvbox.runtime.BytecodeCompatibility.rewrite(original, rewritten);
                if (!valid(rewritten)) throw new java.io.IOException("Converted plugin contains no JVM classes");
                Files.move(rewritten, compatible, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                tvbox.runtime.PreparationProgress.converted(classCount(compatible));
                System.err.println("DEX_CACHE_CREATED " + key);
            } finally {
                Files.deleteIfExists(original);
                Files.deleteIfExists(rewritten);
            }
        }
        return compatible.toUri().toURL();
    }
    private static int classCount(Path path) {
        try (JarFile jar = new JarFile(path.toFile())) { return (int) jar.stream().filter(e -> e.getName().endsWith(".class")).count(); }
        catch (java.io.IOException ignored) { return 0; }
    }
    private static boolean valid(Path path) {
        if (!Files.isRegularFile(path)) return false;
        try (JarFile jar = new JarFile(path.toFile())) {
            return jar.stream().anyMatch(entry -> entry.getName().endsWith(".class"));
        } catch (java.io.IOException corrupt) { return false; }
    }
}
