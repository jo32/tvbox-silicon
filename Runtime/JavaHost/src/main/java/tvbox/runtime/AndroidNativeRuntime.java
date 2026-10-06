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
    private static AndroidEmulator emulator;
    private static VM vm;
    private static ClassLoader loader;
    private static File plugin;
    private static File cache;
    private static final HashSet<String> loaded = new HashSet<>();

    public static void configure(ClassLoader classLoader, File archive, File directory) {
        loader = classLoader; plugin = archive; cache = directory;
    }

    private static void initialize() {
        if (vm != null) return;
        File root = new File(cache, "android-guest"); root.mkdirs();
        emulator = new HeadlessAndroidEmulator(root);
        emulator.setTimeout(10_000_000L);
        emulator.getMemory().setLibraryResolver(new AndroidResolver(23));
        vm = emulator.createDalvikVM();
        vm.setDvmClassFactory(new HierarchyProxyFactory(loader).configClassNameMapper(name -> {
            try { return Class.forName(name, false, loader); }
            catch (ClassNotFoundException absent) {
                try { return dalvik.system.DexClassLoader.current == null ? null : Class.forName(name, false, dalvik.system.DexClassLoader.current); }
                catch (ClassNotFoundException missing) { return null; }
            }
        }));
        vm.setJni(new AbstractJni() {});
        vm.setVerbose(Boolean.getBoolean("tvbox.traceJNI"));
        new AndroidModule(emulator, vm).register(emulator.getMemory());
    }

    public static synchronized void close() throws java.io.IOException {
        if (emulator != null) emulator.close();
        emulator = null; vm = null; loaded.clear(); loader = null; plugin = null; cache = null;
    }

    public static synchronized void load(String path) {
        try {
            File file = new File(path).getCanonicalFile();
            if (loaded.contains(file.getPath())) return;
            byte[] header;
            try (var stream = Files.newInputStream(file.toPath())) { header = stream.readNBytes(20); }
            NativeLibraries.validateARM64(header, file.getName());
            initialize();
            vm.loadLibrary(file, true).callJNI_OnLoad(emulator);
            loaded.add(file.getPath());
        } catch (Exception error) { throw new IllegalStateException("Cannot load Android native library: " + new File(path).getName(), error); }
    }

    public static synchronized void loadLibrary(String name) {
        try {
            load(NativeLibraries.resolve(plugin, name, cache.toPath().resolve("native")).toString());
        } catch (Exception error) { throw new IllegalStateException("Cannot load bundled Android library: " + name, error); }
    }

    public static synchronized Object invoke(String owner, String signature, Object receiver, Object[] values) {
        if (vm == null) throw new IllegalStateException("Plugin called JNI before loading its native library: " + owner);
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
