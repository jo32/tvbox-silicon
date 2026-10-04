import tvbox.runtime.CloudDriveBridge;
import org.json.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.io.*;
import java.util.*;

public class CloudDriveBridgeTest {
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
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
            check(Files.exists(cache.resolve("proxy-active")), "Playback lease not updated");
            check(bridge.rewriteAddress("https://example.com/proxy?do=quark").startsWith("https://example.com"), "Remote proxy rewritten");
            String array = bridge.playback("{\"url\":[\"HD\",\"http://127.0.0.1:9978/proxy?do=quark\"],\"header\":{\"Referer\":\"https://example.com\"}}");
            check(new JSONObject(array).getJSONArray("url").getString(1).contains("/media?"), "Quality array lost proxy routing");
            check(bridge.extension("{\"Cloud-drive\":\"original\"}", new JSONObject()).contains("original"), "Empty credentials replaced existing config");
        }
        cloudFamilyCredentials();
        proxyAddressMethodsUseHost();
        System.out.println("Cloud bridge checks passed (credentials, capability, range streaming, quality arrays).");
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
