package tvbox.runtime;

/** Loaded with each session, so plugin paths never leak through process properties. */
public final class HostEnvironment {
    public static String cache;
    public static String converted;
    public static String plugin;
    private HostEnvironment() {}
    public static String cache(String fallback) { return cache == null ? System.getProperty("tvbox.cache", fallback) : cache; }
    public static String converted(String fallback) { return converted == null ? System.getProperty("tvbox.converted", fallback) : converted; }
    public static String plugin() { return plugin == null ? System.getProperty("tvbox.plugin", "") : plugin; }
}
