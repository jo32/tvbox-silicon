import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import org.jf.dexlib2.*;
import org.jf.dexlib2.iface.instruction.Instruction;
import org.jf.dexlib2.immutable.*;
import org.jf.dexlib2.immutable.instruction.*;
import org.jf.dexlib2.immutable.reference.*;
import org.jf.dexlib2.writer.io.MemoryDataStore;
import org.jf.dexlib2.writer.pool.DexPool;
import org.json.JSONObject;
import tvbox.runtime.ConvertAhead;
import tvbox.runtime.LazyDexArchive;

/**
 * Ahead-of-time conversion (issue #274) converts the sources' spiders and what they reach, the most shared
 * classes first, in batches, and leaves the rest of the archive alone. It stops while the app is busy, and a
 * later request reuses what it converted.
 */
public final class ConvertAheadTest {
    static final String SPIDER = "Lcom/github/catvod/spider/";
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    /** A class whose static run() calls run() on each of `calls`. */
    static ImmutableClassDef caller(String name, String... calls) {
        List<Instruction> code = new ArrayList<>();
        for (String target : calls) code.add(new ImmutableInstruction35c(Opcode.INVOKE_STATIC, 0, 0, 0, 0, 0, 0, new ImmutableMethodReference(target, "run", List.of(), "V")));
        code.add(new ImmutableInstruction10x(Opcode.RETURN_VOID));
        int open = AccessFlags.PUBLIC.getValue();
        return new ImmutableClassDef(name, open, "Ljava/lang/Object;", List.of(), null, Set.of(), List.of(), List.of(
            new ImmutableMethod(name, "run", List.of(), "V", open | AccessFlags.STATIC.getValue(), Set.of(), Set.of(),
                new ImmutableMethodImplementation(0, code, null, null))));
    }

    static Path archive(Path folder, String file, ImmutableClassDef... classes) throws Exception {
        var pool = new DexPool(Opcodes.forApi(23));
        for (var definition : classes) pool.internClass(definition);
        var store = new MemoryDataStore();
        pool.writeTo(store);
        Path jar = folder.resolve(file);
        try (var zip = new ZipOutputStream(Files.newOutputStream(jar))) {
            zip.putNextEntry(new ZipEntry("classes.dex"));
            zip.write(Arrays.copyOf(store.getBuffer(), store.getSize()));
        }
        return jar;
    }

    static JSONObject batch(Path jar, Path cache, int from, int batch, boolean busy) throws Exception {
        var input = new JSONObject().put("jar", jar.toString()).put("conversionCache", cache.toString())
            .put("spiders", new org.json.JSONArray(List.of("Alpha", "Beta", "Missing"))).put("limit", 5).put("batch", batch).put("from", from);
        return ConvertAhead.run(input, () -> busy);
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("convert-ahead-test");
        try {
            Path cache = root.resolve("Converted");
            String shared = "Lplugin/Shared;", alphaOnly = "Lplugin/AlphaOnly;", betaOnly = "Lplugin/BetaOnly;", deep = "Lplugin/Deep;";
            Path jar = archive(root, "plugin.jar",
                caller(SPIDER + "Alpha;", shared, alphaOnly), caller(SPIDER + "Beta;", shared, betaOnly), caller(SPIDER + "Init;", shared),
                caller(shared), caller(alphaOnly, deep), caller(betaOnly), caller(deep), caller("Lplugin/Unused;"), caller(SPIDER + "Other;", shared));

            var probe = new LazyDexArchive(jar.toString(), cache);
            List<String> likely = ConvertAhead.likely(probe, List.of("com.github.catvod.spider.Alpha", "com.github.catvod.spider.Beta", "com.github.catvod.spider.Init"), 100, () -> false);
            check(likely.subList(0, 4).equals(List.of("com.github.catvod.spider.Alpha", "com.github.catvod.spider.Beta", "com.github.catvod.spider.Init", "plugin.Shared")),
                "spiders first, then the class all three reach: " + likely);
            check(likely.indexOf("plugin.AlphaOnly") < likely.indexOf("plugin.Deep"), "a nearer class goes first among equally shared ones: " + likely);
            check(!likely.contains("plugin.Unused") && !likely.contains("com.github.catvod.spider.Other"), "classes no source reaches were planned: " + likely);
            check(ConvertAhead.likely(probe, List.of("com.github.catvod.spider.Alpha"), 100, () -> true) == null, "planning did not stop for a request");

            var stopped = batch(jar, cache, 0, 2, true);
            check(stopped.getString("stopped").equals("busy") && stopped.getInt("converted") == 0 && !stopped.getBoolean("done"), "converted while the app was busy: " + stopped);
            int from = 0, converted = 0, calls = 0;
            JSONObject result;
            do {
                result = batch(jar, cache, from, 2, false);
                check(result.getInt("converted") <= 2, "batch too large: " + result);
                converted += result.getInt("converted");
                from = result.getInt("next");
                check(++calls < 10, "never finished: " + result);
            } while (!result.getBoolean("done"));
            check(result.getInt("planned") == 5 && converted == 5, "limit not kept: " + result + " converted=" + converted);
            for (String name : List.of("com.github.catvod.spider.Alpha", "com.github.catvod.spider.Beta", "com.github.catvod.spider.Init", "plugin.Shared"))
                check(probe.converted(name), name + " was not converted");
            check(!probe.converted("plugin.Unused"), "an unrelated class was converted");

            var again = batch(jar, cache, 0, 10, false);
            check(again.getInt("converted") == 0 && again.getInt("reused") == 5 && again.getBoolean("done"), "the second pass converted again: " + again);

            // A request after it loads the converted classes without converting them.
            System.setProperty("tvbox.lazyDex", "true");
            var log = new java.io.ByteArrayOutputStream(); var previous = System.err;
            tvbox.runtime.HostEnvironment.converted = cache.toString();
            try (var loader = new dalvik.system.DexClassLoader(jar.toString(), root.resolve("job").toString(), "", ConvertAheadTest.class.getClassLoader())) {
                System.setErr(new java.io.PrintStream(log));
                loader.loadClass("com.github.catvod.spider.Alpha").getMethod("run").invoke(null);
            } finally { System.setErr(previous); tvbox.runtime.HostEnvironment.converted = null; }
            check(!log.toString().contains("DEX_CLASS_BEGIN com.github.catvod.spider.Alpha") && !log.toString().contains("DEX_CLASS_BEGIN plugin.Shared"),
                "the request converted classes again:\n" + log);

            // An archive whose classes are encrypted (an FTY guard's loader) has none of the spiders.
            Path guarded = archive(root, "guarded.jar", caller("Lcom/guard/Loader;"));
            var none = ConvertAhead.run(new JSONObject().put("jar", guarded.toString()).put("conversionCache", cache.toString())
                .put("spiders", new org.json.JSONArray(List.of("Alpha"))), () -> false);
            check(none.getBoolean("done") && none.getInt("converted") == 0 && none.getInt("planned") == 0, "a guarded archive was converted: " + none);
        } finally {
            try (var files = Files.walk(root)) { for (Path p : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); }
        }
        System.out.println("ConvertAheadTest passed: likely classes first, limit and batches, stops while busy, reuse by requests, guarded archives skipped");
    }
}
