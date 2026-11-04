package tvbox.runtime;

import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.*;
import com.github.unidbg.linux.android.dvm.jni.ProxyDvmObject;
import com.github.unidbg.virtualmodule.android.AndroidModule;
import java.io.File;
import java.nio.file.Files;
import java.util.HashSet;
import org.objectweb.asm.Type;

/** Routes plugin JNI into an Android guest. Android ELF is never loaded into macOS. */
public final class AndroidNativeRuntime {
    /**
     * One emulator per nesting level. On Android, native code may call Java that calls native code again
     * (the aowu proxyInvoke runs the spider's Java proxy, which calls MyCrypto in another library). A
     * unidbg emulator cannot start a run inside a run ("IllegalStateException: running"), so a nested call
     * goes to the next guest, which has loaded the same libraries. Most plugins only ever use the first.
     */
    private static final class Guest {
        final AndroidEmulator emulator;
        final VM vm;
        final HashSet<File> libraries = new HashSet<>();
        Guest(File root) {
            emulator = new HeadlessAndroidEmulator(root);
            emulator.setTimeout(10_000_000L);
            emulator.getMemory().setLibraryResolver(new AndroidResolver(23));
            vm = emulator.createDalvikVM();
            vm.setDvmClassFactory(new HierarchyProxyFactory(loader).configClassNameMapper(name -> {
                // A class a plugin loader handed to native code keeps meaning that class, not a same-named stub.
                Class<?> handed = dalvik.system.DexClassLoader.guestClass(name);
                if (handed != null) return handed;
                try { return Class.forName(name, false, loader); }
                catch (ClassNotFoundException absent) { return dalvik.system.DexClassLoader.pluginClass(name); }
            }));
            vm.setJni(new AbstractJni() {});
            vm.setVerbose(Boolean.getBoolean("tvbox.traceJNI"));
            new AndroidModule(emulator, vm).register(emulator.getMemory());
        }
        void load(File library) {
            if (!libraries.add(library)) return;
            vm.loadLibrary(library, true).callJNI_OnLoad(emulator);
        }
    }

    /** Deeper nesting than this is runaway recursion, not a plugin pattern. */
    private static final int MAX_GUESTS = 4;
    private static final java.util.ArrayList<Guest> guests = new java.util.ArrayList<>();
    private static ClassLoader loader;
    private static File plugin;
    private static File cache;
    private static File guestRoot;
    private static final HashSet<String> loaded = new HashSet<>();
    /** Every library loaded so far, as kept copies in load order: a new guest loads them all. */
    private static final java.util.ArrayList<File> libraries = new java.util.ArrayList<>();
    /** Libraries loaded from Java code that guest native code called into; see {@link #load}. */
    private static final java.util.ArrayList<File> deferred = new java.util.ArrayList<>();
    private static int depth;

    public static void configure(ClassLoader classLoader, File archive, File directory) {
        loader = classLoader; plugin = archive; cache = directory;
    }

    private static void initialize() {
        if (!guests.isEmpty()) return;
        File root = new File(cache, "android-guest"); root.mkdirs();
        guestRoot = root;
        guests.add(new Guest(root));
    }

    /** The guest for the current nesting level, created with every library loaded so far. */
    private static Guest guest(int level) {
        if (level >= MAX_GUESTS) throw new IllegalStateException("Native code nested " + level + " calls deep");
        while (guests.size() <= level) {
            System.err.println("NATIVE_GUEST " + guests.size() + " for a nested native call");
            Guest guest = new Guest(guestRoot);
            for (File library : libraries) guest.load(library);
            guests.add(guest);
        }
        return guests.get(level);
    }

    /** Native code writes files inside the guest file system; map such a path back to the host. */
    public static synchronized String hostPath(String path) {
        if (path == null || guestRoot == null || new File(path).exists() || !path.startsWith("/")) return path;
        File guest = new File(guestRoot, path.substring(1));
        return guest.exists() ? guest.getPath() : path;
    }

    public static synchronized void close() throws java.io.IOException {
        for (Guest guest : guests) guest.emulator.close();
        guests.clear(); guestRoot = null; loaded.clear(); libraries.clear(); deferred.clear(); depth = 0; loader = null; plugin = null; cache = null;
    }

    public static synchronized void load(String path) {
        try {
            File file = new File(hostPath(path)).getCanonicalFile();
            if (loaded.contains(file.getPath())) return;
            byte[] header;
            try (var stream = Files.newInputStream(file.toPath())) { header = stream.readNBytes(20); }
            NativeLibraries.validateARM64(header, file.getName());
            initialize();
            // Keep a copy: plugins often delete the extracted file right after System.load, and a nested
            // guest created later, or a deferred load, still needs it.
            File copy = new File(new File(cache, "native-loaded"), Integer.toHexString(file.getPath().hashCode()) + "-" + file.getName());
            copy.getParentFile().mkdirs();
            Files.copy(file.toPath(), copy.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            if (depth > 0) {
                // Guest code called Java (e.g. a class initializer) that loads another library. The busy
                // emulator cannot start a nested run, so load it once the outer call returns.
                deferred.add(copy);
                libraries.add(copy);
                loaded.add(file.getPath());
                System.err.println("NATIVE_LOAD_DEFERRED " + file.getName());
                return;
            }
            for (Guest guest : guests) guest.load(copy);
            libraries.add(copy);
            loaded.add(file.getPath());
        } catch (Exception error) {
            // Plugins usually catch this and print only the message.
            System.err.println("NATIVE_LOAD_FAILED " + path);
            error.printStackTrace(System.err);
            throw new IllegalStateException("Cannot load Android native library: " + new File(path).getName(), error);
        }
    }

    public static synchronized void loadLibrary(String name) {
        try {
            load(NativeLibraries.resolve(plugin, name, cache.toPath().resolve("native")).toString());
        } catch (Exception error) { throw new IllegalStateException("Cannot load bundled Android library: " + name, error); }
    }

    private static void loadDeferred() {
        while (depth == 0 && !deferred.isEmpty()) {
            File file = deferred.remove(0);
            for (Guest guest : guests) {
                try { guest.load(file); }
                catch (Exception error) { System.err.println("NATIVE_LOAD_FAILED " + file); error.printStackTrace(System.err); }
            }
        }
    }

    public static synchronized Object invoke(String owner, String signature, Object receiver, Object[] values) {
        if (guests.isEmpty()) throw new IllegalStateException("Plugin called JNI before loading its native library: " + owner);
        loadDeferred();
        Guest guest = guest(depth);
        depth++;
        try { return call(guest, owner, signature, receiver, values); }
        finally { depth--; loadDeferred(); }
    }

    private static Object call(Guest guest, String owner, String signature, Object receiver, Object[] values) {
        VM vm = guest.vm;
        AndroidEmulator emulator = guest.emulator;
        Type[] types = Type.getArgumentTypes(signature.substring(signature.indexOf('(')));
        Object[] arguments = new Object[values.length];
        for (int i = 0; i < values.length; i++) {
            arguments[i] = types[i].getSort() >= Type.ARRAY ? ProxyDvmObject.createObject(vm, values[i]) : values[i];
        }
        DvmClass cls = vm.resolveClass(owner);
        DvmObject<?> object = receiver == null ? null : ProxyDvmObject.createObject(vm, receiver);
        Type result = Type.getReturnType(signature.substring(signature.indexOf('(')));
        switch (result.getSort()) {
            case Type.VOID:
                if (object == null) cls.callStaticJniMethod(emulator, signature, arguments);
                else object.callJniMethod(emulator, signature, arguments);
                return null;
            case Type.BOOLEAN:
                return object == null ? cls.callStaticJniMethodBoolean(emulator, signature, arguments) : object.callJniMethodBoolean(emulator, signature, arguments);
            case Type.LONG:
                return object == null ? cls.callStaticJniMethodLong(emulator, signature, arguments) : object.callJniMethodLong(emulator, signature, arguments);
            case Type.BYTE: case Type.CHAR: case Type.SHORT: case Type.INT:
                int number = object == null ? cls.callStaticJniMethodInt(emulator, signature, arguments) : object.callJniMethodInt(emulator, signature, arguments);
                if (result.getSort() == Type.BYTE) return (byte) number;
                if (result.getSort() == Type.SHORT) return (short) number;
                if (result.getSort() == Type.CHAR) return (char) number;
                return number;
            case Type.ARRAY: case Type.OBJECT:
                DvmObject<?> value = object == null ? cls.callStaticJniMethodObject(emulator, signature, arguments) : object.callJniMethodObject(emulator, signature, arguments);
                Object unwrapped = value == null ? null : value.getValue();
                if (unwrapped instanceof DvmObject<?>[] array) {
                    try {
                        Class<?> component = Class.forName(result.getDescriptor().replace('/', '.'), false, loader).getComponentType();
                        Object output = java.lang.reflect.Array.newInstance(component, array.length);
                        for (int i = 0; i < array.length; i++) java.lang.reflect.Array.set(output, i, array[i] == null ? null : array[i].getValue());
                        return output;
                    } catch (ClassNotFoundException error) { throw new IllegalStateException(error); }
                }
                return unwrapped;
            default: throw new UnsupportedOperationException("Floating-point JNI return is not supported: " + signature);
        }
    }
}
