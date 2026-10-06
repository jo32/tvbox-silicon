import dalvik.system.DexClassLoader;
import java.nio.file.*;
import org.json.JSONObject;
import tvbox.runtime.PreparationProgress;

public final class PreparationProgressTest {
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("preparation-progress-test");
        System.setProperty("tvbox.lazyDex", "true");
        try {
            PreparationProgress.begin(root);
            try(var loader = new DexClassLoader("Tests/TVCoreTests/Fixtures/runtime-probe.jar", root.toString(), "", PreparationProgressTest.class.getClassLoader())) {
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null) == 42, "Cold load failed");
            }
            PreparationProgress.loading();
            JSONObject cold = new JSONObject(Files.readString(root.resolve("preparation-progress.json")));
            check(cold.getInt("converted") > 0 && cold.getInt("reused") == 0, "Cold conversion was not reported");
            PreparationProgress.begin(root);
            try(var loader = new DexClassLoader("Tests/TVCoreTests/Fixtures/runtime-probe.jar", root.toString(), "", PreparationProgressTest.class.getClassLoader())) {
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null) == 42, "Warm load failed");
            }
            PreparationProgress.loading();
            JSONObject warm = new JSONObject(Files.readString(root.resolve("preparation-progress.json")));
            check(warm.getInt("converted") == 0 && warm.getInt("reused") > 0, "Cache reuse was not reported");
            check(!warm.has("total") && !warm.has("percent"), "Lazy conversion invented a total");
            // An unwritable/missing progress destination must not prevent conversion.
            PreparationProgress.begin(root.resolve("missing/child"));
            PreparationProgress.converting(); PreparationProgress.converted(1); PreparationProgress.loading();
            System.out.println("PreparationProgressTest passed: cold work, warm reuse, reset, best-effort writes");
        } finally {
            System.clearProperty("tvbox.lazyDex");
            try(var files=Files.walk(root)) { for(Path path:files.sorted(java.util.Comparator.reverseOrder()).toList()) Files.deleteIfExists(path); }
        }
    }
}
