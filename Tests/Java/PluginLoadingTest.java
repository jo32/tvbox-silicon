import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.zip.*;
import org.json.JSONObject;
import tvbox.runtime.*;

/** Exercises the actual process protocol with a plain CatVod plugin and no .so. */
public class PluginLoadingTest {
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("plugin-loading-test");
        try {
            Path sources = root.resolve("src/com/github/catvod/spider"); Files.createDirectories(sources);
            Files.writeString(sources.resolve("Init.java"), """
                package com.github.catvod.spider;
                public final class Init {
                    public static String value;
                    public static void init(android.content.Context context) { value = context.getPackageName(); }
                }
                """);
            Files.writeString(sources.resolve("PlainFixture.java"), """
                package com.github.catvod.spider;
                public final class PlainFixture extends com.github.catvod.crawler.Spider {
                    public String homeContent(boolean filter) throws Exception {
                        if (!"com.fongmi.android.tv".equals(Init.value)) throw new Exception("Plugin Init was shadowed");
                        try (var asset = getClass().getClassLoader().getResourceAsStream("assets/fixture.txt")) {
                            if (asset == null || !new String(asset.readAllBytes()).equals("kept")) throw new Exception("Archive asset lost");
                        }
                        return "{\\"class\\":[{\\"type_id\\":\\"movies\\"}],\\"list\\":[{\\"vod_id\\":\\"one\\"}]}";
                    }
                    public String searchContent(String query, boolean quick, String page) {
                        return "{\\"list\\":[{\\"vod_id\\":\\"found\\",\\"vod_name\\":\\"" + query + "\\"}]}";
                    }
                }
                """);
            Path classes = root.resolve("classes"); Files.createDirectories(classes);
            int compiled = javax.tools.ToolProvider.getSystemJavaCompiler().run(null, null, null,
                "-cp", System.getProperty("java.class.path"), "-d", classes.toString(),
                sources.resolve("Init.java").toString(), sources.resolve("PlainFixture.java").toString());
            check(compiled == 0, "Fixture compilation failed");
            Path jar = root.resolve("plain.jar");
            try (var zip = new ZipOutputStream(Files.newOutputStream(jar)); var files = Files.walk(classes)) {
                for (Path file : files.filter(Files::isRegularFile).toList()) {
                    zip.putNextEntry(new ZipEntry(classes.relativize(file).toString())); zip.write(Files.readAllBytes(file)); zip.closeEntry();
                }
                zip.putNextEntry(new ZipEntry("assets/fixture.txt")); zip.write("kept".getBytes()); zip.closeEntry();
            }
            for (JSONObject params : List.of(new JSONObject(), new JSONObject().put("wd", "中文搜索").put("pg", "1"))) {
                Path job = Files.createTempDirectory(root, "job-");
                Path request = job.resolve("request.json");
                Files.writeString(request, new JSONObject().put("jar", jar.toString()).put("cache", job.toString())
                    .put("conversionCache", root.resolve("converted").toString()).put("api", "csp_PlainFixture").put("params", params).toString());
                Process process = new ProcessBuilder(System.getProperty("java.home") + "/bin/java", "-cp", System.getProperty("java.class.path"),
                    "tvbox.runtime.NativeProbe", request.toString()).redirectOutput(job.resolve("result.json").toFile()).redirectError(job.resolve("log").toFile()).start();
                try {
                    check(process.waitFor(20, TimeUnit.SECONDS), "Plugin host timed out");
                    String response = Files.readString(job.resolve("result.json"));
                    check(process.exitValue() == 0, "Plugin host failed: " + response + Files.readString(job.resolve("log")));
                    JSONObject payload = new JSONObject(new JSONObject(response).getString("result"));
                    check(payload.getJSONArray("list").length() == 1, "No plugin result");
                    if (params.has("wd")) check(payload.getJSONArray("list").getJSONObject(0).getString("vod_name").equals("中文搜索"), "Search query lost");
                } finally { if (process.isAlive()) process.destroyForcibly(); }
            }
            System.out.println("Plain plugin home/search, Init isolation, and assets passed without any native library.");
        } finally {
            try (var paths = Files.walk(root)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }
}
