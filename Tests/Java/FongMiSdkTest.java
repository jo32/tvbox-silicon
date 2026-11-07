import com.github.catvod.crawler.Spider;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import org.json.JSONObject;

/**
 * FongMi's new spider SDK (the 前瞻版 subscription, #500): spiders get `net` and `local` before init and reach the
 * app through com.github.catvod.Runtime. Before the host had them, every spider of that JAR failed with
 * NoSuchFieldError: net.
 */
public final class FongMiSdkTest {
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    public static void main(String[] args) {
        // OkHttp's dispatcher thread would keep the JVM alive for another minute either way.
        try { run(); } catch (Throwable error) { error.printStackTrace(); System.exit(1); }
        System.exit(0);
    }

    static void run() throws Exception {
        Path root = Files.createTempDirectory("fongmi-sdk-test");
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            String body = exchange.getRequestMethod() + " " + new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8)
                + " cookie=" + Objects.toString(exchange.getRequestHeaders().getFirst("Cookie"), "");
            if (exchange.getRequestURI().getPath().equals("/json")) body = "{\"ok\":true}";
            if (exchange.getRequestURI().getPath().equals("/login")) exchange.getResponseHeaders().add("Set-Cookie", "sid=abc; Path=/");
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            exchange.getResponseBody().write(bytes);
            exchange.close();
        });
        server.start();
        var bridge = new tvbox.runtime.CloudDriveBridge(root.resolve("bridge"));
        try {
            String base = "http://127.0.0.1:" + server.getAddress().getPort();
            var context = new android.app.Application(root.resolve("profile").toFile(), FongMiSdkTest.class.getClassLoader());
            com.github.catvod.Runtime.set(context);
            com.github.catvod.Runtime.setDialog((options, callback) -> com.github.catvod.utils.Task.failedFuture(new UnsupportedOperationException("no dialogs")));

            Spider spider = new Spider() { };
            check(spider.net == null && spider.local == null, "a classic spider got the new SDK's fields without a site key");
            spider.siteKey = "wanou";
            tvbox.runtime.NativeProbe.attachSdk(spider);
            check(spider.net != null && spider.local != null, "the spider has no net or local");

            // Net: text, JSON, the request envelope, and the web view's cookies when a request asks for them.
            check(spider.net.get(base + "/page").equals("GET  cookie="), "get");
            check(spider.net.post(base + "/page", "{\"a\":1}").startsWith("POST {\"a\":1}"), "post");
            check(new JSONObject(spider.net.json(base + "/json", "{}")).getBoolean("ok"), "json");
            JSONObject reply = new JSONObject(spider.net.req(base + "/login", "{\"cookie\":true}"));
            check(reply.getInt("code") == 200, "req envelope: " + reply);
            check(spider.net.getCookie(base + "/").equals("sid=abc"), "Set-Cookie went to the cookie jar: " + spider.net.getCookie(base + "/"));
            check(new JSONObject(spider.net.req(base + "/page", "{\"cookie\":true}")).getString("content").endsWith("cookie=sid=abc"), "the cookie jar's cookie went out");
            String ttl = "{\"ttl\":60000}";
            check(spider.net.cached("k", ttl, () -> "[1]").equals("[1]") && spider.net.cached("k", ttl, () -> "[2]").equals("[1]"), "cached");

            // Local: JSON values per site, kept on disk.
            spider.local.set("account", "{\"name\":\"x\"}");
            check("{\"name\":\"x\"}".equals(new com.github.catvod.utils.Local("wanou").get("account")), "local");
            check(new com.github.catvod.utils.Local("muou").get("account") == null, "local is per site");

            // Spider helpers: the proxy address the host routes back to Spider.proxy, scripts, dialogs.
            bridge.activate();
            String proxy = spider.proxyUrl(Map.of("url", "a b"));
            check(proxy.startsWith(tvbox.runtime.CloudDriveBridge.getUrl() + "?do=jar&siteKey=wanou&url=a%20b"), "proxyUrl: " + proxy);
            try { spider.js.eval("1+1"); throw new AssertionError("js.eval ran without QuickJS"); } catch (UnsupportedOperationException expected) { }
            try { spider.dialog(new JSONObject()); throw new AssertionError("dialog opened"); } catch (java.util.concurrent.ExecutionException expected) { check(expected.getCause() instanceof UnsupportedOperationException, "dialog: " + expected); }

            spider.closeHostResources();
            try { spider.net.get(base + "/page"); throw new AssertionError("net works after the source closed"); } catch (IllegalStateException expected) { }

            // The app's drive sign-ins reach the JAR's account store once; the plugin's own sign-in then stays.
            String store = "spider_local_" + java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
                .digest("com.github.catvod.pan.accounts.v1".getBytes(StandardCharsets.UTF_8)));
            var accounts = context.getSharedPreferences(store, 0);
            tvbox.runtime.CloudDriveBridge.seedFongMiPanCookies(new JSONObject().put("quarkCookie", "q=1").put("pan115Cookie", "u=2"), context);
            check(new JSONObject(accounts.getString("quark", "{}")).getString("cookie").equals("q=1"), "quark seeded");
            check(new JSONObject(accounts.getString("115", "{}")).getString("cookie").equals("u=2"), "115 seeded");
            check(accounts.getString("baidu", null) == null, "baidu without an app sign-in");
            accounts.edit().putString("quark", "{\"cookie\":\"q=refreshed\"}").commit();
            tvbox.runtime.CloudDriveBridge.seedFongMiPanCookies(new JSONObject().put("quarkCookie", "q=1"), context);
            check(new JSONObject(accounts.getString("quark", "{}")).getString("cookie").equals("q=refreshed"), "the plugin's refreshed cookie was replaced");
            tvbox.runtime.CloudDriveBridge.seedFongMiPanCookies(new JSONObject().put("quarkCookie", "q=new"), context);
            check(new JSONObject(accounts.getString("quark", "{}")).getString("cookie").equals("q=new"), "a new app sign-in didn't reach the plugin");
            System.out.println("FongMiSdkTest passed");
        } finally {
            server.stop(0);
            bridge.close();
            try (var files = Files.walk(root)) { files.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete()); }
        }
    }
}
