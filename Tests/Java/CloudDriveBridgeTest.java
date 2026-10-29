import tvbox.runtime.CloudDriveBridge;
import org.json.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.io.*;
import java.util.*;

public class CloudDriveBridgeTest {
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    static String sha256(String text) throws Exception {
        return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(text.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
    }
    static HttpURLConnection connection(String address) throws Exception {
        var connection = (HttpURLConnection)new URL(address).openConnection();
        connection.setConnectTimeout(2000); connection.setReadTimeout(2000); return connection;
    }
    public static void main(String[] args) throws Exception {
        Path cache = Files.createTempDirectory("cloud-bridge-test");
        try (var bridge = new CloudDriveBridge(cache)) {
            var accounts = new JSONObject().put("quarkCookie", "__pus=test-only").put("ucCookie", "__pus=uc-test").put("token", "test-token");
            var ext = new JSONObject(bridge.extension("{\"Cloud-drive\":\"tvfan/Cloud-drive.txt\",\"cookie\":\"http://127.0.0.1:9978/file/TVBox/quark.txt\",\"siteUrl\":\"https://example.com\"}", accounts));
            check(ext.getString("siteUrl").equals("https://example.com"), "Source settings changed");
            String address = ext.getString("Cloud-drive");
            var config = connection(address);
            check(new JSONObject(new String(config.getInputStream().readAllBytes(), StandardCharsets.UTF_8)).getString("quarkCookie").equals("__pus=test-only"), "Cloud config was not delivered");
            var cookie = connection(ext.getString("cookie"));
            check(new String(cookie.getInputStream().readAllBytes(), StandardCharsets.UTF_8).equals("__pus=test-only"), "Legacy cookie file failed");
            check(connection(address.replaceAll("/[a-f0-9-]+/accounts$", "/accounts")).getResponseCode() == 403, "Missing capability accepted");
            var crossOrigin = connection(address); crossOrigin.setRequestProperty("Origin", "https://example.com");
            // JDK may filter Origin unless explicitly enabled; the process sets the property below.
            check(crossOrigin.getResponseCode() == 403, "Browser origin accepted");
            check(connection(address + "/../private").getResponseCode() == 404, "Unknown file accepted");
            bridge.setProxy(params -> {
                check("bytes=2-4".equals(params.get("range")), "Range header lost");
                check("a+b".equals(params.get("id")), "Query decoding failed");
                return new Object[]{206, "video/mp4", new ByteArrayInputStream("234".getBytes()), Map.of("Content-Range", "bytes 2-4/10", "Accept-Ranges", "bytes")};
            });
            String media = bridge.rewriteAddress("http://127.0.0.1:9978/proxy?do=quark&id=a%2Bb");
            check(!media.contains("/proxy?"), "Proxy was not routed");
            var stream = connection(media); stream.setRequestProperty("Range", "bytes=2-4");
            check(stream.getResponseCode() == 206, "Partial response status lost");
            check("bytes 2-4/10".equals(stream.getHeaderField("Content-Range")), "Content range lost");
            check(new String(stream.getInputStream().readAllBytes()).equals("234"), "Media payload changed");
            bridge.setProxy(params -> new Object[]{200, "video/mp4", new ByteArrayInputStream("01extra".getBytes()),
                Map.of("Content-Range", "bytes 0-1/10", "Content-Length", "10", "Accept-Ranges", "bytes")});
            var probe = connection(media); probe.setRequestProperty("Range", "bytes=0-1");
            check(probe.getResponseCode() == 206, "Zero-offset range must be a partial response");
            check(probe.getContentLengthLong() == 2, "Range response length lost");
            check(new String(probe.getInputStream().readAllBytes()).equals("01"), "Proxy read past the declared range");
            var head = connection(media); head.setRequestMethod("HEAD"); head.setRequestProperty("Range", "bytes=0-1");
            check(head.getResponseCode() == 206 && head.getContentLengthLong() == 2, "HEAD lost range metadata");
            check(head.getInputStream().read() == -1, "HEAD returned a body");
            // FTY's Quark proxy: a short range never starts and an open one says "bytes 0" with the file's length.
            List<String> asked = Collections.synchronizedList(new ArrayList<>());
            bridge.setProxy(params -> {
                asked.add(params.get("range"));
                boolean open = params.get("range").endsWith("-");
                return new Object[]{206, "video/mp4", new ByteArrayInputStream((open ? "0123456789" : "").getBytes()),
                    Map.of("Content-Range", "bytes 0", "Content-Length", "10", "Accept-Ranges", "bytes")};
            });
            var fty = connection(media); fty.setRequestProperty("Range", "bytes=0-1");
            check(fty.getResponseCode() == 206 && "bytes 0-1/10".equals(fty.getHeaderField("Content-Range")), "FTY range not repaired");
            check(new String(fty.getInputStream().readAllBytes()).equals("01"), "FTY range payload changed");
            check(asked.equals(List.of("bytes=0-1", "bytes=0-")), "FTY range was not asked again open: " + asked);
            check(Files.exists(cache.resolve("proxy-active")), "Playback lease not updated");
            check(bridge.rewriteAddress("https://example.com/proxy?do=quark").startsWith("https://example.com"), "Remote proxy rewritten");
            String array = bridge.playback("{\"url\":[\"HD\",\"http://127.0.0.1:9978/proxy?do=quark\"],\"header\":{\"Referer\":\"https://example.com\"}}");
            check(new JSONObject(array).getJSONArray("url").getString(1).contains("/media?"), "Quality array lost proxy routing");
            check(bridge.extension("{\"Cloud-drive\":\"original\"}", new JSONObject()).contains("original"), "Empty credentials replaced existing config");
        }
        cloudFamilyCredentials();
        pluginCookieFiles();
        wexPreferences();
        ftyFamilyCredentials();
        proxyAddressMethodsUseHost();
        suspendedListenerRecovers();
        directMediaRevealsTheCdnRequest();
        connectionDownloadsRevealTheCdnRequest();
        System.out.println("Cloud bridge checks passed (credentials, capability, range streaming, quality arrays).");
    }
    /** The app streams drive files itself: the bridge reveals the CDN request behind a proxy address. */
    static void directMediaRevealsTheCdnRequest() throws Exception {
        long total = 1_480_000_000L;
        List<String> upstreamRanges = Collections.synchronizedList(new ArrayList<>());
        var cdn = new okhttp3.OkHttpClient.Builder().addInterceptor(chain -> {
            var request = chain.request();
            String range = request.header("Range");
            upstreamRanges.add(range);
            String[] span = range.substring("bytes=".length()).split("-");
            long first = Long.parseLong(span[0]), last = Long.parseLong(span[1]);
            return new okhttp3.Response.Builder().request(request).protocol(okhttp3.Protocol.HTTP_1_1).code(206).message("Partial Content")
                .header("Content-Range", "bytes " + first + "-" + last + "/" + total)
                .body(okhttp3.ResponseBody.create(new byte[(int)(last - first + 1)], okhttp3.MediaType.get("video/mp4"))).build();
        }).build();
        try (var bridge = new CloudDriveBridge(Files.createTempDirectory("cloud-direct-test"))) {
            // Like FTY's downloader: the requested bytes come from a larger upstream chunk, fetched on its own thread.
            bridge.setDriveProxy((params, path, headers) -> {
                String[] span = headers.get("range").substring("bytes=".length()).split("-");
                long first = Long.parseLong(span[0]), last = Long.parseLong(span[1]);
                var pipe = new PipedInputStream(); var sink = new PipedOutputStream(pipe);
                new Thread(() -> {
                    try (sink) {
                        var call = cdn.newCall(new okhttp3.Request.Builder().url("https://dl.example.cn/file/abc?sign=s1")
                            .header("Cookie", "__pus=test-only").header("Referer", "https://pan.example.cn/")
                            .header("Range", "bytes=" + first + "-" + (first + 1_048_575)).build());
                        try (var response = tvbox.runtime.HttpDiagnostics.execute(call)) { sink.write(response.body().bytes(), 0, (int)(last - first + 1)); }
                    } catch (IOException ignored) { }
                }).start();
                return new Object[]{206, "video/mp4", pipe, Map.of("Content-Range", "bytes " + first + "-" + last + "/" + total)};
            });
            String address = CloudDriveBridge.getOwnProxyUrl("play") + "drive-name/192.mp3";
            var media = new JSONObject(bridge.directMedia(address));
            check(media.getString("url").equals("https://dl.example.cn/file/abc?sign=s1"), "CDN address not revealed");
            check(media.getLong("length") == total, "File length lost");
            var headers = media.getJSONObject("headers");
            check("__pus=test-only".equals(headers.optString("Cookie")) && "https://pan.example.cn/".equals(headers.optString("Referer")), "CDN headers lost");
            check(!headers.has("Range"), "A range was kept as a fixed header");
            check(upstreamRanges.size() == 1, "The probe should cost one upstream request");
            check(bridge.directMedia("http://127.0.0.1:9/other/drive/x") == null, "Foreign address accepted");
            check(bridge.directMedia(CloudDriveBridge.getUrl() + "?do=quark") == null, "A media address without a ranged answer was accepted");
        }
    }

    /** A CDN connection that answers every range with 206, recording the ranges it was asked for. */
    static final class FakeCdnConnection extends HttpURLConnection {
        final long total; final List<String> ranges;
        FakeCdnConnection(URL url, long total, List<String> ranges) { super(url); this.total = total; this.ranges = ranges; }
        @Override public void connect() { if (!connected) { ranges.add(getRequestProperty("Range")); connected = true; } }
        @Override public void disconnect() { }
        @Override public boolean usingProxy() { return false; }
        @Override public int getResponseCode() { connect(); return 206; }
        @Override public String getHeaderField(String name) { connect(); return "Content-Range".equalsIgnoreCase(name) ? "bytes 0-1048575/" + total : null; }
        @Override public InputStream getInputStream() { connect(); return new ByteArrayInputStream(new byte[1_048_576]); }
    }

    /**
     * Fish's drives proxy through /media and download ranges over HttpURLConnection on their own
     * threads. The converted plugin's calls are rewritten, so the bridge still learns the CDN request.
     */
    static void connectionDownloadsRevealTheCdnRequest() throws Exception {
        Path folder = Files.createTempDirectory("cloud-connection-test");
        Path source = folder.resolve("original.jar"), rewritten = folder.resolve("rewritten.jar");
        var writer = new org.objectweb.asm.ClassWriter(0);
        writer.visit(52, 1, "com/github/catvod/spider/merge/A/Downloader", null, "java/lang/Object", null);
        var status = writer.visitMethod(9, "fetch", "(Ljava/net/HttpURLConnection;)I", null, new String[]{"java/io/IOException"});
        status.visitCode(); status.visitVarInsn(25, 0);
        status.visitMethodInsn(182, "java/net/HttpURLConnection", "getResponseCode", "()I", false);
        status.visitInsn(172); status.visitMaxs(1, 1); status.visitEnd();
        var body = writer.visitMethod(9, "body", "(Ljava/net/URLConnection;)Ljava/io/InputStream;", null, new String[]{"java/io/IOException"});
        body.visitCode(); body.visitVarInsn(25, 0);
        body.visitMethodInsn(182, "java/net/URLConnection", "getInputStream", "()Ljava/io/InputStream;", false);
        body.visitInsn(176); body.visitMaxs(1, 1); body.visitEnd();
        writer.visitEnd();
        try (var zip = new java.util.zip.ZipOutputStream(Files.newOutputStream(source))) {
            zip.putNextEntry(new java.util.zip.ZipEntry("com/github/catvod/spider/merge/A/Downloader.class")); zip.write(writer.toByteArray()); zip.closeEntry();
        }
        tvbox.runtime.BytecodeCompatibility.rewrite(source, rewritten);
        long total = 2_040_000_000L;
        List<String> ranges = Collections.synchronizedList(new ArrayList<>());
        @SuppressWarnings("deprecation")
        URL cdn = new URL(null, "https://cdn.example.cn/v/abc?sign=s2", new URLStreamHandler() {
            @Override protected URLConnection openConnection(URL url) { return new FakeCdnConnection(url, total, ranges); }
        });
        try (var bridge = new CloudDriveBridge(folder); var loader = new URLClassLoader(new URL[]{rewritten.toUri().toURL()}, CloudDriveBridgeTest.class.getClassLoader())) {
            var plugin = loader.loadClass("com.github.catvod.spider.merge.A.Downloader");
            bridge.setProxy(params -> {
                String[] span = params.get("range").substring("bytes=".length()).split("-");
                long first = Long.parseLong(span[0]), last = Long.parseLong(span[1]);
                var pipe = new PipedInputStream(); var sink = new PipedOutputStream(pipe);
                new Thread(() -> {
                    try (sink) {
                        var connection = (HttpURLConnection) cdn.openConnection();
                        connection.setRequestProperty("Cookie", "BDUSS=test-only"); connection.setRequestProperty("User-Agent", "netdisk");
                        connection.setRequestProperty("Range", "bytes=" + first + "-" + (first + 1_048_575));
                        check((Integer) plugin.getMethod("fetch", HttpURLConnection.class).invoke(null, connection) == 206, "CDN status lost");
                        try (var stream = (InputStream) plugin.getMethod("body", URLConnection.class).invoke(null, connection)) {
                            sink.write(stream.readNBytes((int) (last - first + 1)));
                        }
                    } catch (Exception ignored) { }
                }).start();
                return new Object[]{206, "video/mp4", pipe, Map.of("Content-Range", "bytes " + first + "-" + last + "/" + total)};
            });
            var media = new JSONObject(bridge.directMedia(bridge.rewriteAddress("http://127.0.0.1:9978/proxy?do=fish&id=1")));
            check(media.getString("url").equals(cdn.toString()), "CDN address not revealed");
            check(media.getLong("length") == total, "File length lost");
            var headers = media.getJSONObject("headers");
            check("BDUSS=test-only".equals(headers.optString("Cookie")) && "netdisk".equals(headers.optString("User-Agent")), "CDN headers lost");
            check(!headers.has("Range"), "A range was kept as a fixed header");
            check(ranges.size() == 1, "The probe should cost one upstream request");
            // A playlist (or anything not served as a byte range) is left to the proxy straight away.
            bridge.setProxy(params -> new Object[]{200, "application/vnd.apple.mpegurl", new ByteArrayInputStream("#EXTM3U\n".getBytes()), Map.of()});
            long started = System.nanoTime();
            check(bridge.directMedia(CloudDriveBridge.getUrl() + "?do=m3u8&id=2") == null, "A playlist was taken for a file");
            check(System.nanoTime() - started < 2_000_000_000L, "A playlist waited for a CDN request");
        }
    }

    static void suspendedListenerRecovers() throws Exception {
        try (var bridge = new CloudDriveBridge(Files.createTempDirectory("cloud-resume-test"))) {
            bridge.setProxy(params -> new Object[]{200, "video/mp4", new ByteArrayInputStream("video".getBytes()), Map.of("Content-Length", "5")});
            String address = CloudDriveBridge.getUrl();
            check(connection(address).getResponseCode() == 200, "Initial listener did not start");
            var field = CloudDriveBridge.class.getDeclaredField("server"); field.setAccessible(true);
            var original = (com.sun.net.httpserver.HttpServer)field.get(bridge);
            check(bridge.recoverProxy("http://127.0.0.1:1/unrelated") == null, "Unrelated localhost URL was claimed");
            check(bridge.recoverProxy(address.replaceFirst("/[a-z0-9-]+/", "/wrong/")) == null, "Another capability was claimed");
            original.stop(0); // Models a socket invalidated while the process remains alive.
            var session = new tvbox.runtime.PluginSession(new com.github.catvod.crawler.Spider() {}, null, bridge);
            String recovered = session.recoverProxy(address);
            check(address.equals(recovered), "Recovery should preserve the port for cached player URLs");
            check(field.get(bridge) != original, "Dead listener was retained");
            check(new String(connection(recovered).getInputStream().readAllBytes()).equals("video"), "Recovered listener did not serve bytes");
            var restarted = field.get(bridge);
            bridge.ensureAvailable();
            check(field.get(bridge) == restarted, "Healthy listener was restarted");
            ((com.sun.net.httpserver.HttpServer)restarted).stop(0);
            bridge.playback(new JSONObject().put("url", address).toString());
            check(connection(address).getResponseCode() == 200, "Fresh playback did not recover its listener");
            bridge.close();
            try { bridge.ensureAvailable(); throw new AssertionError("Closed source was resurrected"); }
            catch (IOException expected) { }
        }
    }
    static void proxyAddressMethodsUseHost() throws Exception {
        Path folder = Files.createTempDirectory("cloud-methods-test");
        Path source = folder.resolve("original.jar"), rewritten = folder.resolve("rewritten.jar");
        var writer = new org.objectweb.asm.ClassWriter(0);
        writer.visit(52, 1, "com/github/catvod/spider/ProxyOrigin", null, "java/lang/Object", null);
        for (String name : List.of("getUrl", "getOwnProxyUrl")) {
            var method = writer.visitMethod(9, name, "()Ljava/lang/String;", null, null);
            method.visitCode(); method.visitLdcInsn("android-only"); method.visitInsn(176); method.visitMaxs(1, 0); method.visitEnd();
        }
        var method = writer.visitMethod(9, "getOwnProxyUrl", "(Ljava/lang/String;)Ljava/lang/String;", null, null);
        method.visitCode(); method.visitLdcInsn("android-only"); method.visitInsn(176); method.visitMaxs(1, 1); method.visitEnd();
        writer.visitEnd();
        try (var zip = new java.util.zip.ZipOutputStream(Files.newOutputStream(source))) {
            zip.putNextEntry(new java.util.zip.ZipEntry("com/github/catvod/spider/ProxyOrigin.class")); zip.write(writer.toByteArray()); zip.closeEntry();
        }
        tvbox.runtime.BytecodeCompatibility.rewrite(source, rewritten);
        try (var bridge = new CloudDriveBridge(folder); var loader = new java.net.URLClassLoader(new URL[]{rewritten.toUri().toURL()}, CloudDriveBridgeTest.class.getClassLoader())) {
            var proxy = loader.loadClass("com.github.catvod.spider.ProxyOrigin");
            check(((String)proxy.getMethod("getUrl").invoke(null)).endsWith("/media"), "Main proxy adapter failed");
            check(((String)proxy.getMethod("getOwnProxyUrl").invoke(null)).endsWith("/drive/"), "Drive root adapter failed");
            check(((String)proxy.getMethod("getOwnProxyUrl", String.class).invoke(null, "qk")).endsWith("/drive/proxy/qk/"), "Named drive adapter failed");
        }
    }

    static void ftyFamilyCredentials() throws Exception {
        class Loader extends ClassLoader {
            final Map<String, byte[]> classes = new HashMap<>();
            Class<?> define(String name, String parent, java.util.function.Consumer<org.objectweb.asm.ClassWriter> body) {
                var w = new org.objectweb.asm.ClassWriter(org.objectweb.asm.ClassWriter.COMPUTE_MAXS);
                w.visit(52, 1, name, null, parent, null);
                body.accept(w);
                w.visitEnd(); byte[] bytes = w.toByteArray();
                classes.put(name + ".class", bytes);
                return defineClass(name.replace('/', '.'), bytes, 0, bytes.length);
            }
            @Override public InputStream getResourceAsStream(String name) {
                byte[] bytes = classes.get(name);
                return bytes == null ? super.getResourceAsStream(name) : new ByteArrayInputStream(bytes);
            }
        }
        // {account class, singleton, web cookie, mobile ticket, other String, Pan's Quark field}: FTY renames
        // all of them between releases (N0 until 2026-10-21, k with renamed fields since 2026-10-22).
        // The last layout's response handler stores two Strings, so which one is the cookie is unclear.
        for (List<String> layout : List.of(List.of("N0", "Zm", "F5", "W", "ee", "yq"), List.of("k", "OW", "W", "ee", "xa", "Gd"),
                List.of("k", "OW", "W", "ee", "xa", "ambiguous"))) {
            String account = "com/github/catvod/spider/merge/" + layout.get(0), self = "L" + account + ";";
            boolean ambiguous = layout.get(5).equals("ambiguous");
            var loader = new Loader();
            var type = loader.define(account, "java/lang/Object", w -> {
                for (String field : layout.subList(2, 5)) w.visitField(1, field, "Ljava/lang/String;", null, null).visitEnd();
                w.visitField(9, "instance", self, null, null).visitEnd();
                var init = w.visitMethod(1, "<init>", "()V", null, null);
                init.visitCode(); init.visitVarInsn(25, 0); init.visitMethodInsn(183, "java/lang/Object", "<init>", "()V", false);
                init.visitInsn(177); init.visitMaxs(0, 0); init.visitEnd();
                var singleton = w.visitMethod(9, layout.get(1), "()" + self, null, null);
                singleton.visitCode(); singleton.visitFieldInsn(178, account, "instance", self); singleton.visitInsn(176); singleton.visitMaxs(0, 0); singleton.visitEnd();
                // The sign-in response handler stores the web cookie.
                var response = w.visitMethod(2, "U", "(Lokhttp3/Response;Ljava/lang/String;)Z", null, null);
                response.visitCode();
                for (String field : ambiguous ? layout.subList(2, 5) : layout.subList(2, 3)) {
                    response.visitVarInsn(25, 0); response.visitVarInsn(25, 2); response.visitFieldInsn(181, account, field, "Ljava/lang/String;");
                }
                response.visitInsn(3); response.visitInsn(172); response.visitMaxs(0, 0); response.visitEnd();
                // The static setter stores the mobile ticket; a sibling with the same shape stores nothing.
                for (String setter : List.of("yq", "SN")) {
                    var method = w.visitMethod(9, setter, "(" + self + "Ljava/lang/String;)V", null, null);
                    method.visitCode();
                    if (setter.equals("yq")) { method.visitVarInsn(25, 0); method.visitVarInsn(25, 1); method.visitFieldInsn(181, account, layout.get(3), "Ljava/lang/String;"); }
                    method.visitInsn(177); method.visitMaxs(0, 0); method.visitEnd();
                }
            });
            loader.define("com/github/catvod/spider/Cloud_quark", "java/lang/Object", w -> {
                var play = w.visitMethod(1, "play", "()V", null, null);
                play.visitCode(); play.visitMethodInsn(184, account, layout.get(1), "()" + self, false);
                play.visitInsn(87); play.visitInsn(177); play.visitMaxs(0, 0); play.visitEnd();
            });
            loader.define("com/github/catvod/spider/Pan", "java/lang/Object", w ->
                w.visitField(1, layout.get(5), "Lcom/github/catvod/spider/Cloud_quark;", null, null).visitEnd());
            var wogg = loader.define("com/github/catvod/spider/WoGG", "com/github/catvod/spider/Pan", w -> { });
            var instance = type.getConstructor().newInstance(); type.getField("instance").set(null, instance);
            try (var bridge = new CloudDriveBridge(Files.createTempDirectory("fty-cloud-test"))) {
                var accounts = new JSONObject().put("quarkCookie", "__pus=fixture");
                check(!bridge.restoreFtyQuarkAccount(accounts, wogg), "Incomplete legacy login was restored");
                accounts.put("quarkServiceTicket", "mobile-fixture");
                check(!bridge.restoreFtyQuarkAccount(accounts, Object.class), "Unrelated plugin received credentials");
                check(bridge.restoreFtyQuarkAccount(accounts, wogg) != ambiguous, "FTY login restore didn't match " + layout);
                check(Objects.equals(type.getField(layout.get(2)).get(instance), ambiguous ? null : "__pus=fixture"), "FTY web cookie wrong");
                check(Objects.equals(type.getField(layout.get(3)).get(instance), ambiguous ? null : "mobile-fixture"), "FTY mobile ticket wrong");
                check(type.getField(layout.get(4)).get(instance) == null, "External-source account was changed");
            }
        }
    }

    /** csp_Config's Pan spiders read raw cookies from files/.quark, .uc and .baidu (issue #171). */
    static void pluginCookieFiles() throws Exception {
        Path files = Files.createTempDirectory("plugin-cookie-test").resolve("files");
        CloudDriveBridge.seedDriveCookies(null, files);
        Files.createDirectories(files);
        Files.writeString(files.resolve(".uc"), "{}");
        Files.writeString(files.resolve(".baidu"), "BDUSS=old");
        var accounts = new JSONObject().put("quarkCookie", " __pus=quark-fixture ").put("ucCookie", "__pus=uc-fixture").put("baiduCookie", "BDUSS=new; STOKEN=s");
        CloudDriveBridge.seedDriveCookies(accounts, files);
        check(Files.readString(files.resolve(".quark")).equals("__pus=quark-fixture"), "Quark cookie not seeded");
        check(Files.readString(files.resolve(".uc")).equals("{}"), "Another plugin's JSON file was overwritten");
        check(Files.readString(files.resolve(".baidu")).equals("BDUSS=new; STOKEN=s"), "The app's Baidu sign-in did not replace the old one");
        CloudDriveBridge.seedDriveCookies(new JSONObject(), files);
        check(Files.readString(files.resolve(".quark")).equals("__pus=quark-fixture"), "A missing account erased the plugin's cookie");
        // The sx.jar family reads Quark and UC from shared storage next to files/, and never gets the Baidu sign-in.
        Path shared = files.resolveSibling("external").resolve("TVBox");
        check(Files.readString(shared.resolve("quark_cookie.txt")).equals("__pus=quark-fixture"), "Quark cookie not seeded into TVBox/quark_cookie.txt");
        check(Files.readString(shared.resolve("uc_cookie.txt")).equals("__pus=uc-fixture"), "UC cookie not seeded into TVBox/uc_cookie.txt");
        check(!Files.exists(shared.resolve("baidu.txt")), "The Baidu sign-in reached TVBox/baidu.txt");
    }

    static void wexPreferences() throws Exception {
        var context = new android.content.Context(Files.createTempDirectory("wex-cookie-test").toFile(), CloudDriveBridgeTest.class.getClassLoader());
        var preferences = context.getSharedPreferences(CloudDriveBridge.WEX_PREFERENCES, 0);
        CloudDriveBridge.seedWexCookies(null, context);
        var accounts = new JSONObject().put("quarkCookie", " __pus=quark-fixture ").put("baiduCookie", "BDUSS=b; STOKEN=s");
        CloudDriveBridge.seedWexCookies(accounts, context);
        check(preferences.getString("Wex_quark_cookie", "").equals("__pus=quark-fixture"), "Quark cookie not given to the Wex preferences");
        check(preferences.getString("Wex_baidu_cookie", "").equals("BDUSS=b; STOKEN=s"), "Baidu cookie not given to the Wex preferences");
        check(!preferences.contains("Wex_ucpan_cookie"), "A missing UC account was written");
        // The plugin refreshes its cookie; the same app sign-in must not undo that.
        preferences.edit().putString("Wex_quark_cookie", "__pus=refreshed").commit();
        CloudDriveBridge.seedWexCookies(accounts, context);
        check(preferences.getString("Wex_quark_cookie", "").equals("__pus=refreshed"), "An unchanged sign-in replaced the plugin's refreshed cookie");
        CloudDriveBridge.seedWexCookies(accounts.put("quarkCookie", "__pus=signed-in-again"), context);
        check(preferences.getString("Wex_quark_cookie", "").equals("__pus=signed-in-again"), "A new app sign-in did not replace the plugin's cookie");
        var reopened = new android.content.Context(context.getFilesDir().getParentFile(), CloudDriveBridgeTest.class.getClassLoader());
        check(reopened.getSharedPreferences(CloudDriveBridge.WEX_PREFERENCES, 0).getString("Wex_baidu_cookie", "").equals("BDUSS=b; STOKEN=s"), "Wex preferences not saved to disk");

        // Sign-ins one Wex source made through its own code reach a source (or jar version) that never saw them.
        var other = new android.content.Context(Files.createTempDirectory("wex-shared-test").toFile(), CloudDriveBridgeTest.class.getClassLoader());
        var shared = new JSONObject().put("Wex_pan115_cookie", "UID=115").put("Wex_quark_cookie", "__pus=plugin")
            .put("yingxia.replaced.Wex_quark_cookie", sha256("__pus=signed-in-again")).put("yingxia.other", "x");
        var withShared = new JSONObject(accounts.toString()).put("wexPreferences", shared);
        CloudDriveBridge.seedWexCookies(withShared, other);
        var otherPreferences = other.getSharedPreferences(CloudDriveBridge.WEX_PREFERENCES, 0);
        check(otherPreferences.getString("Wex_pan115_cookie", "").equals("UID=115"), "A plugin's own 115 sign-in did not reach another source");
        check(otherPreferences.getString("Wex_quark_cookie", "").equals("__pus=plugin"), "The plugin's Quark sign-in did not replace the app sign-in it refused");
        check(!otherPreferences.contains("yingxia.other"), "Something other than a Wex preference was shared");
        // A plugin sign-in noted against an older app sign-in is not used.
        var older = new android.content.Context(Files.createTempDirectory("wex-older-test").toFile(), CloudDriveBridgeTest.class.getClassLoader());
        CloudDriveBridge.seedWexCookies(new JSONObject(withShared.toString()).put("quarkCookie", "__pus=newest"), older);
        check(older.getSharedPreferences(CloudDriveBridge.WEX_PREFERENCES, 0).getString("Wex_quark_cookie", "").equals("__pus=newest"), "A plugin sign-in beat a newer app sign-in");
        // The user signs in to Quark again in the app: that sign-in wins again; 115 stays.
        CloudDriveBridge.seedWexCookies(withShared.put("quarkCookie", "__pus=newest"), other);
        check(otherPreferences.getString("Wex_quark_cookie", "").equals("__pus=newest"), "A new app sign-in did not replace the plugin's Quark sign-in");
        check(otherPreferences.getString("Wex_pan115_cookie", "").equals("UID=115"), "The shared 115 sign-in was lost");
    }

    static void cloudFamilyCredentials() throws Exception {
        class Loader extends ClassLoader {
            Class<?> define(String name, String parent, boolean fields) {
                var writer = new org.objectweb.asm.ClassWriter(0);
                writer.visit(52, 1, name, null, parent, null);
                if (fields) {
                    writer.visitField(1, "a", "Lcom/github/catvod/spider/Quark;", null, null).visitEnd();
                    writer.visitField(1, "c", "Lcom/github/catvod/spider/UC;", null, null).visitEnd();
                }
                writer.visitEnd(); byte[] bytes = writer.toByteArray();
                return defineClass(name.replace('/', '.'), bytes, 0, bytes.length);
            }
        }
        var loader = new Loader();
        loader.define("com/github/catvod/spider/Quark", "java/lang/Object", false);
        loader.define("com/github/catvod/spider/UC", "java/lang/Object", false);
        loader.define("com/github/catvod/spider/Cloud", "java/lang/Object", true);
        var wogg = loader.define("com/github/catvod/spider/Wogg", "com/github/catvod/spider/Cloud", false);
        try (var bridge = new CloudDriveBridge(Files.createTempDirectory("cloud-family-test"))) {
            String original = "{\"site\":[\"https://example.com\"]}";
            var accounts = new JSONObject().put("quarkCookie", "__pus=quark-fixture").put("ucCookie", "__pus=uc-fixture").put("token", "ali-fixture");
            var ext = new JSONObject(bridge.cloudExtension(original, accounts, wogg));
            check(ext.getString("cookie").equals("__pus=quark-fixture"), "Wogg requires an inline cookie even without an existing ext key");
            check(ext.getString("uccookie").equals("__pus=uc-fixture"), "Wogg UC credential key is uccookie");
            check(ext.getString("token").equals("ali-fixture"), "Ali account mapping failed");
            check(ext.getJSONArray("site").getString(0).equals("https://example.com"), "Source origin changed");
            check(bridge.cloudExtension(original, accounts, Object.class).equals(original), "Unrelated plugin received accounts");
        }
    }

}
