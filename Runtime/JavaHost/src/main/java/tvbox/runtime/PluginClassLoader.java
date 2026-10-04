package tvbox.runtime;

/** Retain each plugin's Init/helpers while sharing the CatVod host contract. */
public final class PluginClassLoader extends dalvik.system.DexClassLoader {
    public PluginClassLoader(String path, String cache, ClassLoader parent) throws Exception {
        super(path, cache, "", parent);
    }
    @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
        synchronized (getClassLoadingLock(name)) {
            Class<?> loaded = findLoadedClass(name);
            if (loaded == null && name.startsWith("com.github.catvod.") && !name.startsWith("com.github.catvod.crawler.")) {
                try { loaded = findClass(name); } catch (ClassNotFoundException absent) { }
            }
            if (loaded == null) loaded = super.loadClass(name, false);
            if (resolve) resolveClass(loaded);
            return loaded;
        }
    }
}
