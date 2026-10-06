import java.net.URI;
import javax.net.ssl.HttpsURLConnection;

public final class RuntimeSpike {
    public static String convert(String archive, String cache) throws Exception {
        System.out.println("CONVERSION_STARTED bytes=" + java.nio.file.Files.size(java.nio.file.Path.of(archive)));
        long started = System.nanoTime();
        try (var names = RuntimeSpike.class.getResourceAsStream("/benchmark-classes.txt")) {
            if (names != null) {
                var type = Class.forName("tvbox.runtime.LazyDexArchive");
                var constructor = type.getConstructor(String.class, String.class);
                var prepare = type.getMethod("prepare", String.class);
                var directory = java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(cache), "conversion-benchmark-");
                try {
                    Object archiveReader = constructor.newInstance(archive, directory.toString());
                    String[] classes = new String(names.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim().split(",");
                    for (String name : classes) prepare.invoke(archiveReader, name.trim());
                    double cold = (System.nanoTime() - started) / 1e9;
                    long warmStart = System.nanoTime();
                    // Include rebuilding the DEX index, as a real app restart does.
                    archiveReader = constructor.newInstance(archive, directory.toString());
                    for (String name : classes) prepare.invoke(archiveReader, name.trim());
                    double warm = (System.nanoTime() - warmStart) / 1e9;
                    return String.format("CONVERSION_BENCHMARK classes=%d cold=%.3fs warm=%.3fs", classes.length, cold, warm);
                } finally {
                    try (var paths = java.nio.file.Files.walk(directory)) {
                        for (var path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) java.nio.file.Files.deleteIfExists(path);
                    }
                }
            }
        }
        var work = new java.util.concurrent.FutureTask<String>(() -> {
            Class<?> type = Class.forName("tvbox.runtime.PluginClassLoader");
            try (var loader = (java.net.URLClassLoader) type.getConstructor(String.class, String.class, ClassLoader.class)
                    .newInstance(archive, cache, RuntimeSpike.class.getClassLoader())) {
                double seconds = (System.nanoTime() - started) / 1e9;
                long heap = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();
                return String.format("CONVERSION_PASS seconds=%.3f usedHeapMB=%d", seconds, heap / (1024 * 1024));
            }
        });
        Thread thread = new Thread(work, "conversion-spike"); thread.setDaemon(true); thread.start();
        try { return work.get(1800, java.util.concurrent.TimeUnit.SECONDS); }
        catch (java.util.concurrent.TimeoutException timeout) {
            // Interruption cannot safely stop arbitrary Java code. The harness must
            // terminate this test app after collecting the no-go result.
            work.cancel(true);
            return "CONVERSION_NO_GO: exceeded 1800 seconds; terminate the spike app to stop the worker";
        }
    }

    public static String run() throws Exception {
        String vm = System.getProperty("java.vm.name");
        if (!vm.toLowerCase().contains("zero")) throw new IllegalStateException("Expected Zero, got " + vm);
        HttpsURLConnection connection = (HttpsURLConnection) URI.create("https://example.com/").toURL().openConnection();
        connection.setConnectTimeout(15000);
        connection.setReadTimeout(15000);
        try {
            int status = connection.getResponseCode();
            if (status != 200) throw new IllegalStateException("HTTPS status " + status);
            try (var stream = connection.getInputStream()) {
                if (stream.read() < 0) throw new IllegalStateException("HTTPS returned no body");
            }
            return "Hello from " + vm + " " + System.getProperty("java.version") + "; HTTPS 200";
        } finally { connection.disconnect(); }
    }
}
