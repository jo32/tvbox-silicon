package tvbox.runtime;

/**
 * Java heap headroom. On Apple platforms one JVM serves every source, so plugin runtimes and
 * spiders are kept only while the heap has room for the next one, not up to a fixed count.
 */
public final class HeapBudget {
    private static final long MB = 1024 * 1024;
    private HeapBudget() {}

    private static long used() { var runtime = Runtime.getRuntime(); return runtime.totalMemory() - runtime.freeMemory(); }
    private static long max() { return Runtime.getRuntime().maxMemory(); }

    /**
     * Free heap kept in reserve before opening another runtime or source: a quarter of the heap,
     * at least 96 MB. Opening a plugin archive and its Init needs tens of megabytes at once.
     */
    private static long reserve() { return Math.max(96 * MB, max() / 4); }

    /**
     * True when the heap is short of the reserve even after a full collection. The collection
     * runs only when the cheap estimate is already short, since garbage counts as used.
     */
    public static boolean low() {
        if (max() - used() >= reserve()) return false;
        System.gc();
        return max() - used() < reserve();
    }

    /** Reflection, class initialization and executors wrap the error the plugin hit. */
    public static boolean outOfMemory(Throwable error) {
        for (int depth = 0; error != null && depth < 16; depth++, error = error.getCause()) {
            if (error instanceof OutOfMemoryError) return true;
        }
        return false;
    }

    public static String describe() { return "heap=" + used() / MB + "/" + max() / MB + "MB"; }
}
