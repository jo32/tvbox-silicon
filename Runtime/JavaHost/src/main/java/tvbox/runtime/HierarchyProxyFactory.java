package tvbox.runtime;
import com.github.unidbg.linux.android.dvm.*;
import com.github.unidbg.linux.android.dvm.jni.ProxyClassFactory;
/** Preserve Java inheritance even when JNI FindClass precedes NewObject. */
public final class HierarchyProxyFactory extends ProxyClassFactory {
    private final ClassLoader host;
    public HierarchyProxyFactory(ClassLoader host) { super(host); this.host = host; }
    @Override public DvmClass createClass(BaseVM vm, String name, DvmClass parent, DvmClass[] interfaces) {
        if (parent == null && !name.equals("java/lang/Class") && !name.equals("java/lang/Object")) {
            try {
                Class<?> cls = Class.forName(name.replace('/', '.'), false, host);
                if (cls.getSuperclass() != null) parent = vm.resolveClass(cls.getSuperclass().getName().replace('.', '/'));
            } catch (ClassNotFoundException ignored) { }
        }
        return super.createClass(vm, name, parent, interfaces);
    }
}
