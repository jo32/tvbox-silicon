import com.github.catvod.crawler.Spider;
import tvbox.runtime.*;
import org.json.JSONObject;
import org.objectweb.asm.*;
import okhttp3.*;
import java.util.*;

/** Run with Scripts/test-java-host.sh; no network or third-party subscription is needed. */
public class HostCompatibilityTest {
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        if (args.length == 3 && args[0].equals("conversion-worker")) {
            System.setProperty("tvbox.converted", args[2]);
            try (var loader = new dalvik.system.DexClassLoader(args[1], args[2], "", HostCompatibilityTest.class.getClassLoader())) {
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null) == 42, "Concurrent conversion failed");
            }
            return;
        }
        reflectiveArrayCloneWorks(); conversionCacheReusesAndRepairs(); partialInitializationDoesNotHideWorkingSources(); recommendationsMerge(); stateSurvivesAndRestores(); interfaceCallsExecute(); sourceFailuresStaySpecific(); androidScreensAreNamed(); cloudLoginReturnsToTheApp(); asyncCloudLoginEndsPlayback(); packageContextExists(); androidLogHasEveryOverload(); pluginKeepsItsOwnSlf4j(); conversionFailuresNameTheClass();
        System.out.println("Java host regression checks passed (state, interface bytecode, HTTP failures, Android context).");
    }

    private static void androidLogHasEveryOverload() throws Exception {
        // 夸父 (PanWebShareCloudKF) calls Log.w(tag, text, error) in init and failed with NoSuchMethodError.
        Class<?>[] tagText = {String.class, String.class}, withError = {String.class, String.class, Throwable.class};
        for (String name : new String[]{"v", "d", "i", "w", "e", "wtf"}) {
            check(android.util.Log.class.getMethod(name, tagText).getReturnType() == int.class, "Log." + name + "(tag, text) is missing");
            check(android.util.Log.class.getMethod(name, withError).getReturnType() == int.class, "Log." + name + "(tag, text, error) is missing");
        }
        android.util.Log.class.getMethod("w", String.class, Throwable.class);
        android.util.Log.class.getMethod("wtf", String.class, Throwable.class);
        android.util.Log.class.getMethod("println", int.class, String.class, String.class);
        android.util.Log.class.getMethod("isLoggable", String.class, int.class);
        check(android.util.Log.w("test", "warning", null) == 0 && android.util.Log.getStackTraceString(null).isEmpty(), "Log rejected a null error");
    }

    private static void pluginKeepsItsOwnSlf4j() throws Exception {
        // 动漫直链 bundles slf4j with an obfuscated API. The host's slf4j-simple binder took the place of its own:
        // "SimpleLoggerFactory does not implement the requested interface" and NoSuchMethodError in StaticLoggerBinder.
        var folder = java.nio.file.Files.createTempDirectory("plugin-slf4j-test");
        var jar = folder.resolve("plugin.jar");
        try (var output = new java.util.jar.JarOutputStream(java.nio.file.Files.newOutputStream(jar))) {
            var writer = new ClassWriter(0);
            writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC | Opcodes.ACC_SUPER, "org/slf4j/impl/StaticLoggerBinder", null, "java/lang/Object", null);
            writer.visitEnd();
            output.putNextEntry(new java.util.jar.JarEntry("org/slf4j/impl/StaticLoggerBinder.class"));
            output.write(writer.toByteArray());
            output.closeEntry();
        }
        try (var loader = new PluginClassLoader(jar.toString(), folder.toString(), HostCompatibilityTest.class.getClassLoader())) {
            check(loader.loadClass("org.slf4j.impl.StaticLoggerBinder").getClassLoader() == loader, "The host's slf4j replaced the plugin's own");
            check(loader.loadClass("org.slf4j.impl.SimpleLoggerFactory").getClassLoader() != loader, "A plugin without that class lost the host's");
        } finally {
            try (var paths = java.nio.file.Files.walk(folder)) {
                for (var path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) java.nio.file.Files.deleteIfExists(path);
            }
        }
    }

    private static void reflectiveArrayCloneWorks() throws Exception {
        // Wogg initializes its cloud ordering with Object.clone via reflection.
        // Without java.lang being open, it silently stores null and loses every episode.
        var clone = Object.class.getDeclaredMethod("clone");
        clone.setAccessible(true);
        int[] order = {3, 1, 2};
        int[] copied = (int[])ReflectionDiagnostics.invoke(clone, order, new Object[0]);
        check(copied != order && Arrays.equals(order, copied), "Reflective array clone lost cloud ordering");
    }

    private static void conversionCacheReusesAndRepairs() throws Exception {
        var folder = java.nio.file.Files.createTempDirectory("conversion-cache-test");
        var dex = folder.resolve("fixture.dex");
        try (var jar = new java.util.zip.ZipFile("Tests/TVCoreTests/Fixtures/runtime-probe.jar");
             var stream = jar.getInputStream(jar.getEntry("classes.dex"))) {
            java.nio.file.Files.copy(stream, dex);
        }
        String previous = System.getProperty("tvbox.converted");
        System.setProperty("tvbox.converted", folder.resolve("shared").toString());
        try {
            var workers = new java.util.ArrayList<Process>();
            var logs = new java.util.ArrayList<java.nio.file.Path>();
            for (int index = 0; index < 3; index++) {
                var log = folder.resolve("worker-" + index + ".log"); logs.add(log);
                workers.add(new ProcessBuilder(System.getProperty("java.home") + "/bin/java", "-Djava.io.tmpdir=/private/tmp", "-cp", System.getProperty("java.class.path"),
                        "HostCompatibilityTest", "conversion-worker", dex.toString(), folder.resolve("concurrent").toString())
                        .redirectErrorStream(true).redirectOutput(log.toFile()).start());
            }
            try {
                for (var worker : workers) {
                    check(worker.waitFor(20, java.util.concurrent.TimeUnit.SECONDS), "Concurrent converter timed out");
                    check(worker.exitValue() == 0, "Concurrent converter failed");
                }
                long created = 0;
                for (var log : logs) if (java.nio.file.Files.readString(log).contains("DEX_CACHE_CREATED")) created++;
                check(created == 1, "Concurrent sources repeated conversion");
            } finally { for (var worker : workers) if (worker.isAlive()) worker.destroyForcibly(); }
            java.nio.file.Path artifact;
            try (var loader = new dalvik.system.DexClassLoader(dex.toString(), folder.toString(), "", HostCompatibilityTest.class.getClassLoader())) {
                artifact = java.nio.file.Path.of(loader.getURLs()[0].toURI());
                check(artifact.getFileName().toString().contains(BytecodeCompatibility.VERSION), "Cache key lost host version");
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null) == 42, "Converted class did not execute");
            }
            var timestamp = java.nio.file.Files.getLastModifiedTime(artifact);
            try (var loader = new dalvik.system.DexClassLoader(dex.toString(), folder.toString(), "", HostCompatibilityTest.class.getClassLoader())) {
                check(java.nio.file.Files.getLastModifiedTime(artifact).equals(timestamp), "Cache hit repeated conversion");
            }
            java.nio.file.Files.writeString(artifact, "interrupted output");
            try (var loader = new dalvik.system.DexClassLoader(dex.toString(), folder.toString(), "", HostCompatibilityTest.class.getClassLoader())) {
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null) == 42, "Corrupt cache was not repaired");
            }
        } finally {
            if (previous == null) System.clearProperty("tvbox.converted"); else System.setProperty("tvbox.converted", previous);
            try (var paths = java.nio.file.Files.walk(folder)) {
                for (var path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) java.nio.file.Files.deleteIfExists(path);
            }
        }
    }

    private static void partialInitializationDoesNotHideWorkingSources() throws Exception {
        Throwable optionalFailure = new UnsupportedOperationException("optional Android UI");
        PluginSession working = new PluginSession(new Spider() {
            public String homeContent(boolean filter) { return "{}"; }
            public String homeVideoContent() { return "{\"list\":[{\"vod_id\":\"real\"}]}"; }
            public String searchContent(String word, boolean quick) { return "{\"list\":[{\"vod_id\":\"found\"}]}"; }
        }, optionalFailure);
        check(new JSONObject(working.request(new JSONObject())).getJSONArray("list").length() == 1, "Optional initializer failure hid recommendations");
        check(new JSONObject(working.request(new JSONObject().put("wd", "test"))).getJSONArray("list").length() == 1, "Optional initializer failure hid search");
        PluginSession empty = new PluginSession(new Spider() {}, optionalFailure);
        try { empty.request(new JSONObject()); throw new AssertionError("Failed initialization disguised as empty content"); }
        catch (IllegalStateException expected) { check(expected.getCause() == optionalFailure, "Initialization reason lost"); }
    }

    private static void recommendationsMerge() throws Exception {
        PluginSession session = new PluginSession(new Spider() {
            public String homeContent(boolean filter) { return "{\"class\":[{\"type_id\":\"movie\"}],\"list\":[{\"vod_id\":\"old\"}]}"; }
            public String homeVideoContent() { return "{\"list\":[{\"vod_id\":\"recommended\"}]}"; }
        });
        JSONObject home = new JSONObject(session.request(new JSONObject()));
        check(home.getJSONArray("class").length() == 1, "Recommendations lost categories");
        check(home.getJSONArray("list").getJSONObject(0).getString("vod_id").equals("recommended"), "homeVideoContent was ignored");
        PluginSession fallback = new PluginSession(new Spider() {
            public String homeContent(boolean filter) { return "{\"list\":[{\"vod_id\":\"original\"}]}"; }
        });
        check(new JSONObject(fallback.request(new JSONObject())).getJSONArray("list").length() == 1, "Empty recommendations erased home list");
    }

    private static void stateSurvivesAndRestores() throws Exception {
        class Stateful extends Spider {
            String selected;
            int details;
            public String detailContent(List<String> ids) { selected = ids.get(0); details++; return "{\"list\":[]}"; }
            public String playerContent(String flag, String id, List<String> flags) { return "{\"url\":\"https://example.com/" + selected + ".m3u8\"}"; }
        }
        Stateful spider = new Stateful(); PluginSession session = new PluginSession(spider);
        check(session.request(new JSONObject()).equals("{}"), "An empty home must not block search");
        session.request(new JSONObject().put("ids", "a"));
        JSONObject play = new JSONObject().put("play", "episode").put("detailID", "a");
        check(new JSONObject(session.request(play)).getString("url").contains("/a."), "Lost source state");
        check(spider.details == 1, "Repeated detail unnecessarily");
        session.request(new JSONObject().put("ids", "b"));
        check(new JSONObject(session.request(play)).getString("url").contains("/a."), "Playback used a different video's state");
        Stateful restarted = new Stateful();
        new PluginSession(restarted).request(play);
        check(restarted.details == 1 && restarted.selected.equals("a"), "Restarted session did not restore details");
    }

    private static void interfaceCallsExecute() throws Exception {
        ClassWriter writer = new ClassWriter(0);
        writer.visit(Opcodes.V1_6, Opcodes.ACC_PUBLIC, "ConvertedComparator", null, "java/lang/Object", null);
        MethodVisitor method = writer.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "make", "()Ljava/util/Comparator;", null, null);
        method.visitCode();
        // Reproduces the incorrect constant-pool entry emitted for the music spider.
        method.visitMethodInsn(Opcodes.INVOKESTATIC, "java/util/Comparator", "naturalOrder", "()Ljava/util/Comparator;", false);
        method.visitInsn(Opcodes.ARETURN); method.visitMaxs(1, 0); method.visitEnd(); writer.visitEnd();
        var folder = java.nio.file.Files.createTempDirectory("bytecode-test");
        var original = folder.resolve("original.jar"); var patched = folder.resolve("patched.jar");
        try (var zip = new java.util.zip.ZipOutputStream(java.nio.file.Files.newOutputStream(original))) {
            zip.putNextEntry(new java.util.zip.ZipEntry("ConvertedComparator.class")); zip.write(writer.toByteArray()); zip.closeEntry();
        }
        BytecodeCompatibility.rewrite(original, patched);
        Comparator<String> comparator;
        try (var loader = new java.net.URLClassLoader(new java.net.URL[] {patched.toUri().toURL()}, HostCompatibilityTest.class.getClassLoader())) {
            @SuppressWarnings("unchecked") Comparator<String> value = (Comparator<String>)loader.loadClass("ConvertedComparator").getMethod("make").invoke(null);
            comparator = value;
        }
        java.nio.file.Files.delete(original); java.nio.file.Files.delete(patched); java.nio.file.Files.delete(folder);
        check(comparator.compare("a", "b") < 0, "Interface static call failed");
    }

    private static Call response(int code, boolean cookie) {
        OkHttpClient client = new OkHttpClient.Builder().addInterceptor(chain -> {
            Response.Builder result = new Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(code).message("fixture").body(ResponseBody.create("fixture", MediaType.get("text/plain")));
            if (cookie) result.header("Set-Cookie", "fixture=value");
            return result.build();
        }).build();
        return client.newCall(new Request.Builder().url("https://source.example/item").build());
    }

    /** A config center's QR code (issue #171) is a screen the app can't show, not a missing Android feature. */
    private static void androidScreensAreNamed() throws Exception {
        var qr = new RuntimeException("Stub!");
        qr.setStackTrace(new StackTraceElement[]{ new StackTraceElement("android.graphics.Bitmap", "createBitmap", "Bitmap.java", 31),
            new StackTraceElement("com.github.catvod.spider.PanConfig", "categoryContent", null, -1) });
        check(NativeProbe.failure(new java.lang.reflect.InvocationTargetException(qr)).optString("errorCode").equals("android_screen"), "QR dialog not named");
        var media = new RuntimeException("Stub!");
        media.setStackTrace(new StackTraceElement[]{ new StackTraceElement("android.media.MediaPlayer", "start", null, -1) });
        check(NativeProbe.failure(media).optString("errorCode").equals("unsupported_android"), "Other Android stubs changed");
    }

    private static void sourceFailuresStaySpecific() throws Exception {
        HttpDiagnostics.reset();
        try { HttpDiagnostics.executeNewCz(response(403, false)); throw new AssertionError("Missing-cookie response accepted"); }
        catch (HttpDiagnostics.SourceHTTPException error) { check(error.status == 403, "Lost HTTP status"); }
        HttpDiagnostics.reset();
        HttpDiagnostics.executeNewCz(response(403, true)).close();
        HttpDiagnostics.executeNewCz(response(200, false)).close();
        HttpDiagnostics.throwIfFailed();
        PluginSession failing = new PluginSession(new Spider() {
            public String detailContent(List<String> ids) throws Exception {
                HttpDiagnostics.execute(response(503, false)).close(); return "";
            }
        });
        try { failing.request(new JSONObject().put("ids", "a")); throw new AssertionError("HTTP failure was hidden"); }
        catch (HttpDiagnostics.SourceHTTPException error) { check(error.status == 503, "Wrong source failure"); }
    }

    private static void conversionFailuresNameTheClass() throws Exception {
        // Bytecode the verifier rejects was reported as an Android gap, with no class to look at.
        var writer = new ClassWriter(0);
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC, "tvbox/test/Rejected", null, "java/lang/Object", null);
        var method = writer.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "value", "()I", null, null);
        method.visitCode(); method.visitInsn(Opcodes.ACONST_NULL); method.visitInsn(Opcodes.IRETURN); method.visitMaxs(1, 0); method.visitEnd();
        writer.visitEnd();
        byte[] bytes = writer.toByteArray();
        var loader = new ClassLoader(HostCompatibilityTest.class.getClassLoader()) {
            @Override protected Class<?> findClass(String name) throws ClassNotFoundException {
                if (!name.equals("tvbox.test.Rejected")) throw new ClassNotFoundException(name);
                return defineClass(name, bytes, 0, bytes.length);
            }
        };
        JSONObject rejected = NativeProbe.failure(new java.lang.reflect.InvocationTargetException(NativeProbe.spiderFailed("tvbox.test.Rejected", loader)));
        check(rejected.optString("errorCode").equals("class_conversion") && rejected.optString("brokenClass").equals("tvbox.test.Rejected"), "Verifier failure lost its class: " + rejected);
        check(rejected.optString("host").equals(BytecodeCompatibility.VERSION), "Failure did not name the host version");
        check(NativeProbe.rejectedClass("Illegal field name \"a-b\" in class file com/x/Y").equals("com.x.Y"), "ClassFormatError class not found");
        // A spider class the archive lacks keeps the subscription error, which lets the app try another archive.
        JSONObject missing = NativeProbe.failure(NativeProbe.spiderFailed("com.github.catvod.spider.Absent", loader));
        check(missing.optString("error").contains("ClassNotFoundException: com.github.catvod.spider.Absent"), "Missing spider was hidden: " + missing);
    }

    private static void cloudLoginReturnsToTheApp() throws Exception {
        var networkCalls = new java.util.concurrent.atomic.AtomicInteger();
        OkHttpClient client = new OkHttpClient.Builder().addInterceptor(chain -> {
            networkCalls.incrementAndGet();
            return new Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200)
                .message("fixture").body(ResponseBody.create("{}", MediaType.get("application/json"))).build();
        }).build();
        for (String host : List.of("uop.quark.cn", "api.open.uc.cn")) {
            for (String action : List.of("getTokenForQrcodeLogin", "getServiceTicketByQrcodeToken")) {
                PluginSession plugin = new PluginSession(new Spider() {
                    public String playerContent(String flag, String id, List<String> vip) throws Exception {
                        try {
                            HttpDiagnostics.execute(client.newCall(new Request.Builder().url("https://" + host + "/cas/ajax/" + action).build())).close();
                        } catch (Throwable swallowed) { /* Real spiders sometimes return empty content after a failed login. */ }
                        return "{}";
                    }
                });
                try { plugin.request(new JSONObject().put("play", "episode").put("flag", "obscured-provider-name")); throw new AssertionError("QR login stayed inside the plugin"); }
                catch (HttpDiagnostics.CloudLoginRequired login) {
                    String drive = host.equals("uop.quark.cn") ? "quark" : "uc";
                    check(login.drive.equals(drive), "Login provider was lost");
                    JSONObject failure = NativeProbe.failure(new java.lang.reflect.InvocationTargetException(login));
                    check(failure.optString("errorCode").equals("cloud_login_required") && failure.optString("drive").equals(drive), "Login was classified as a plugin crash");
                }
            }
        }
        check(networkCalls.get() == 0, "The plugin started an unusable QR flow");
        HttpDiagnostics.reset();
        // Scope the handoff to the provider's QR endpoints; ordinary drive requests still work.
        for (String url : List.of("https://uop.quark.cn/cas/ajax/other", "https://source.example/cas/ajax/getTokenForQrcodeLogin")) {
            HttpDiagnostics.execute(client.newCall(new Request.Builder().url(url).build())).close();
        }
        check(networkCalls.get() == 2, "Unrelated HTTP requests were intercepted");
    }

    private static void asyncCloudLoginEndsPlayback() throws Exception {
        var executor = java.util.concurrent.Executors.newSingleThreadExecutor();
        // Like FTY's helper pool: created during initialization, before this playback request.
        executor.submit(() -> {}).get();
        HttpDiagnostics.singleSourceRuntime(true);
        try {
            PluginSession plugin = new PluginSession(new Spider() {
                public String playerContent(String flag, String id, List<String> vip) throws Exception {
                    executor.submit(() -> {
                        try {
                            HttpDiagnostics.execute(new OkHttpClient().newCall(new Request.Builder()
                                .url("https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin").build()));
                        } catch (java.io.IOException failure) { throw new RuntimeException(failure); }
                    });
                    long until = System.nanoTime() + 3_000_000_000L;
                    while (System.nanoTime() < until) android.os.SystemClock.sleep(5);
                    return "{}";
                }
            });
            long started = System.nanoTime();
            try { plugin.request(new JSONObject().put("play", "episode")); throw new AssertionError("Playback kept waiting for background QR login"); }
            catch (HttpDiagnostics.CloudLoginRequired login) {
                check(login.drive.equals("quark"), "Background login lost its provider");
                check(System.nanoTime() - started < 1_000_000_000L, "Playback only failed after the poll timed out");
            }
            // The finished request's signal must not poison later plugin calls.
            new PluginSession(new Spider() {
                public String playerContent(String flag, String id, List<String> vip) {
                    android.os.SystemClock.sleep(1); return "{}";
                }
            }).request(new JSONObject().put("play", "next"));
        } finally { HttpDiagnostics.singleSourceRuntime(false); executor.shutdownNow(); }
    }

    private static void packageContextExists() throws Exception {
        java.nio.file.Path folder = java.nio.file.Files.createTempDirectory("host-context-test");
        var application = new android.app.Application(folder.toFile(), HostCompatibilityTest.class.getClassLoader());
        com.github.catvod.spider.Init.application = application;
        check(android.app.ActivityThread.currentApplication() == application, "Missing reflective application lookup");
        check(application instanceof android.content.ContextWrapper, "Wrong Android Application hierarchy");
        check(android.os.Environment.getExternalStorageDirectory().toPath().equals(folder.resolve("external")), "External storage escaped the source profile");
        check(application.getNoBackupFilesDir().isDirectory(), "Missing no-backup storage");
        check(android.os.Process.is64Bit() && dalvik.system.VMRuntime.getRuntime().is64Bit(), "Wrong guest ABI");
        check(android.os.SystemClock.elapsedRealtime() > 0, "Missing monotonic clock");
        check(android.graphics.Color.parseColor("#12abef") == 0xff12abef, "Color parser failed");
        check(application.getPackageManager().getPackageInfo(application.getPackageName(), 0).versionName != null, "Missing host version");
        // 多多 reads its own app name with getApplicationLabel in init and failed with NoSuchMethodError.
        var manager = application.getPackageManager();
        check(manager.getApplicationLabel(manager.getApplicationInfo(application.getPackageName(), 0)).length() > 0, "Missing application label");
        try { application.getPackageManager().getPackageInfo("other.package", 0); throw new AssertionError("Fabricated installed package"); }
        catch (android.content.pm.PackageManager.NameNotFoundException expected) { }
        java.nio.file.Files.delete(folder.resolve("external"));
        java.nio.file.Files.delete(folder.resolve("no_backup"));
        java.nio.file.Files.delete(folder.resolve("files")); java.nio.file.Files.delete(folder);
    }
}
