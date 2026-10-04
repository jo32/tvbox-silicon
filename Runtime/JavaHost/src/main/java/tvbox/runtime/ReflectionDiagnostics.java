package tvbox.runtime;

import java.lang.reflect.*;

/** Keep reflective Android compatibility failures visible when plugins swallow them. */
public final class ReflectionDiagnostics {
    public static Method getMethod(Class<?> type, String name, Class<?>[] arguments) throws NoSuchMethodException {
        try { return type.getMethod(name, arguments); }
        catch (NoSuchMethodException failure) { System.err.println("PLUGIN_REFLECTION " + failure); throw failure; }
    }
    public static Method getDeclaredMethod(Class<?> type, String name, Class<?>[] arguments) throws NoSuchMethodException {
        try { return type.getDeclaredMethod(name, arguments); }
        catch (NoSuchMethodException failure) { System.err.println("PLUGIN_REFLECTION " + failure); throw failure; }
    }
    public static Object invoke(Method method, Object receiver, Object[] arguments) throws IllegalAccessException, InvocationTargetException {
        if (method == null) {
            IllegalStateException failure = new IllegalStateException("Plugin reflection resolved no method");
            failure.printStackTrace(System.err); throw failure;
        }
        if ((method.getDeclaringClass() == System.class || method.getDeclaringClass() == Runtime.class)
            && arguments != null && arguments.length == 1 && arguments[0] instanceof String path) {
            if (method.getName().equals("load")) { AndroidNativeRuntime.load(path); return null; }
            if (method.getName().equals("loadLibrary")) { AndroidNativeRuntime.loadLibrary(path); return null; }
        }
        try { return method.invoke(receiver, arguments); }
        catch (InvocationTargetException failure) {
            System.err.println("PLUGIN_REFLECTION " + method + ": " + failure.getCause());
            throw failure;
        }
    }
}
