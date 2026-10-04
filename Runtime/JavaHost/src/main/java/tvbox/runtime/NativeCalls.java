package tvbox.runtime;
import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.linux.android.dvm.*;
import com.github.unidbg.linux.android.dvm.jni.ProxyDvmObject;
public final class NativeCalls {
    public static AndroidEmulator emulator;
    public static VM vm;
    public static DvmClass nativeClass;
    public static synchronized Object invoke(String signature, Object... values) {
        Object[] arguments = new Object[values.length];
        for (int i=0;i<values.length;i++) arguments[i] = ProxyDvmObject.createObject(vm, values[i]);
        DvmObject<?> result = nativeClass.callStaticJniMethodObject(emulator, signature, arguments);
        return unwrap(result);
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
