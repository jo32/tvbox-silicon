package android.content.res;

import java.io.*;

/** Reads the original plugin archive's assets, which DEX conversion does not contain. */
public final class AssetManager {
    public static final int ACCESS_UNKNOWN = 0, ACCESS_RANDOM = 1, ACCESS_STREAMING = 2, ACCESS_BUFFER = 3;
    private final ClassLoader loader;
    public AssetManager(ClassLoader loader) { this.loader = loader; }
    public InputStream open(String name) throws IOException { return open(name, ACCESS_STREAMING); }
    public InputStream open(String name, int mode) throws IOException {
        InputStream stream = loader.getResourceAsStream("assets/" + name);
        if (stream == null) throw new FileNotFoundException("Plugin asset: " + name);
        return stream;
    }
    /** Entry names directly under assets/path in the plugin archive. */
    public String[] list(String path) throws IOException {
        String prefix = "assets/" + (path == null || path.isEmpty() ? "" : path.endsWith("/") ? path : path + "/");
        var names = new java.util.TreeSet<String>();
        var roots = loader.getResources(prefix.isEmpty() ? "assets/" : prefix);
        while (roots.hasMoreElements()) {
            var url = roots.nextElement();
            if (!"jar".equals(url.getProtocol())) continue;
            var connection = (java.net.JarURLConnection) url.openConnection();
            connection.setUseCaches(false); // A cached JarFile is shared with the class loader; closing it here would break it.
            try (var jar = connection.getJarFile()) {
                for (var entries = jar.entries(); entries.hasMoreElements();) {
                    String name = entries.nextElement().getName();
                    if (!name.startsWith(prefix) || name.length() == prefix.length()) continue;
                    String rest = name.substring(prefix.length());
                    int slash = rest.indexOf('/');
                    names.add(slash < 0 ? rest : rest.substring(0, slash));
                }
            }
        }
        return names.toArray(new String[0]);
    }
    public void close() { }
}
