package tvbox.runtime;
import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.linux.android.dvm.*;
import com.github.unidbg.linux.android.dvm.jni.ProxyDvmObject;
public final class NativeCalls {
    public static AndroidEmulator emulator;
    public static VM vm;
    public static DvmClass nativeClass;
    public static synchronized Object invoke(String signature, Object... values) {
        // Plugin worker threads can outlive their source; never enter a released emulator.
        if (emulator == null) throw new IllegalStateException("The plugin's native library has been released");
        Object[] arguments = new Object[values.length];
        for (int i=0;i<values.length;i++) arguments[i] = ProxyDvmObject.createObject(vm, values[i]);
        DvmObject<?> result = nativeClass.callStaticJniMethodObject(emulator, signature, arguments);
        return unwrap(result);
    }
    /** Waits for a running native call: closing under it frees memory the emulator is executing. */
    public static synchronized void close() throws java.io.IOException {
        if (emulator != null) emulator.close();
        emulator = null; vm = null; nativeClass = null;
    }
    private static Object unwrap(DvmObject<?> result) {
        if(result==null)return null;
        Object value=result.getValue();
        if(value instanceof DvmObject<?>[] array) {
            Object[] converted=new Object[array.length];
            for(int i=0;i<array.length;i++)converted[i]=unwrap(array[i]);
            return converted;
        }
        return value;
    }
}
