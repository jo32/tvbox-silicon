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
    public void close() { }
}
