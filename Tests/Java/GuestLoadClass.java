package com.github.unidbg.test;

/** Stands in for unidbg's JNI bridge (ProxyMethod.call): guest code calling ClassLoader.loadClass through reflection. */
public final class GuestLoadClass {
    public static Class<?> load(ClassLoader loader, String name) throws Exception {
        return (Class<?>) ClassLoader.class.getMethod("loadClass", String.class).invoke(loader, name);
    }
}
