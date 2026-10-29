package tvbox.runtime;

import com.sun.net.httpserver.HttpServer;
import org.json.*;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** Per-process loopback capability for CatVod configuration and proxy responses. */
public final class CloudDriveBridge implements AutoCloseable {
    @FunctionalInterface public interface Proxy { Object[] invoke(Map<String,String> params) throws Exception; }
    @FunctionalInterface public interface DriveProxy { Object[] invoke(Map<String,String> params, String path, Map<String,String> headers) throws Exception; }
    private volatile DriveProxy driveProxy;
    private static volatile CloudDriveBridge current;
    // Concurrent searches run on separate worker threads; each must see its own source's proxy.
    // `current` stays as the fallback for threads a plugin starts itself.
    private static final ThreadLocal<CloudDriveBridge> active = new ThreadLocal<>();
    private static CloudDriveBridge bridge() {
        CloudDriveBridge local = active.get();
        return local != null ? local : current;
    }
    private volatile HttpServer server;
    private boolean closed;
    private final Set<Integer> ports = ConcurrentHashMap.newKeySet();
    private ExecutorService workers = newWorkers();
    private static ExecutorService newWorkers() {
        return Executors.newFixedThreadPool(4, r -> { Thread t = new Thread(r, "cloud-proxy"); t.setDaemon(true); return t; });
    }
    private final String capability = UUID.randomUUID().toString();
    private final Map<String, byte[]> files = new HashMap<>();
    private final Path activity;
    private volatile Proxy proxy;
    private final java.util.concurrent.atomic.AtomicInteger configurationReads = new java.util.concurrent.atomic.AtomicInteger();

    public CloudDriveBridge(Path cache) throws IOException {
        activity = cache.resolve("proxy-active");
        server = listen(0);
        current = this;
        startStandardPort();
    }

    private HttpServer listen(int port) throws IOException {
        HttpServer listener = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 16);
        listener.setExecutor(workers);
        listener.createContext("/", exchange -> {
            try {
                String path = exchange.getRequestURI().getPath();
                if (!path.startsWith("/" + capability + "/") || exchange.getRequestHeaders().containsKey("Origin")) {
                    exchange.sendResponseHeaders(403, -1); return;
                }
                String method = exchange.getRequestMethod();
                if (!method.equals("GET") && !method.equals("HEAD")) { exchange.sendResponseHeaders(405, -1); return; }
                String resource = path.substring(capability.length() + 2);
                if (resource.equals("health")) { exchange.sendResponseHeaders(204, -1); return; }
                if (files.containsKey(resource)) {
                    configurationReads.incrementAndGet();
                    byte[] bytes = files.get(resource);
                    exchange.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
                    exchange.getResponseHeaders().set("Cache-Control", "no-store");
                    exchange.sendResponseHeaders(200, method.equals("HEAD") ? -1 : bytes.length);
                    if (!method.equals("HEAD")) exchange.getResponseBody().write(bytes);
                    return;
                }
                relay(exchange, resource, method);
            } catch (Exception error) {
                // Never print request URLs, credentials, or upstream exception messages.
                System.err.println("CLOUD_PROXY_ERROR " + error.getClass().getSimpleName());
                try { exchange.sendResponseHeaders(502, -1); } catch (IOException ignored) { }
            } finally { exchange.close(); }
        });
        listener.start();
        ports.add(listener.getAddress().getPort());
        return listener;
    }

    /** Apple can invalidate sockets while the app is suspended without destroying its JVM. */
    public synchronized void ensureAvailable() throws IOException {
        if (closed) throw new IOException("Plugin proxy was closed");
        HttpURLConnection probe = null;
        try {
            probe = (HttpURLConnection)URI.create(base() + "health").toURL().openConnection(java.net.Proxy.NO_PROXY);
            probe.setRequestMethod("HEAD"); probe.setConnectTimeout(750); probe.setReadTimeout(1500);
            probe.setUseCaches(false); probe.setRequestProperty("Connection", "close");
            if (probe.getResponseCode() == 204) return;
        } catch (IOException unavailable) {
            // Recover the listener; the spider and its account/session state are still valid.
        } finally { if (probe != null) probe.disconnect(); }
        int port = server.getAddress().getPort();
        server.stop(0);
        workers.shutdownNow(); workers = newWorkers();
        try { server = listen(port); }
        catch (BindException occupied) { server = listen(0); }
        System.err.println("CLOUD_PROXY_RECOVERED");
    }

    public String recoverProxy(String address) throws IOException {
        final URI uri;
        try { uri = URI.create(address); } catch (IllegalArgumentException invalid) { return null; }
        if (!"http".equals(uri.getScheme()) || !"127.0.0.1".equals(uri.getHost())
                || !ports.contains(uri.getPort()) || uri.getRawPath() == null
                || !uri.getRawPath().startsWith("/" + capability + "/")) return null;
        ensureAvailable();
        return base() + uri.getRawPath().substring(capability.length() + 2)
            + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery());
    }

    /**
     * The CDN address and headers behind one of this bridge's drive or media files, as JSON
     * {@code {"url","headers","length"}}, or null. It asks the plugin's proxy for two bytes and
     * records the upstream range request the plugin makes to answer them; when those bytes were
     * already cached, a second probe in the middle of the file forces a fresh request. A proxy
     * that does not answer with a byte range (a playlist, a page) is left alone at once.
     */
    public String directMedia(String address) throws Exception {
        String local = recoverProxy(address);
        if (local == null) return null;
        String path = URI.create(local).getRawPath();
        if (!path.contains("/drive/") && !path.endsWith("/media")) return null;
        synchronized (CloudDriveBridge.class) {
            try {
                long total = -1;
                for (int probe = 0; probe < 2; probe++) {
                    HttpDiagnostics.captureMedia(true);
                    long first = probe == 0 || total < 4 ? 0 : total / 2;
                    HttpURLConnection connection = (HttpURLConnection)URI.create(local).toURL().openConnection(java.net.Proxy.NO_PROXY);
                    try {
                        connection.setConnectTimeout(5000); connection.setReadTimeout(20000); connection.setUseCaches(false);
                        connection.setRequestProperty("Range", "bytes=" + first + "-" + (first + 1));
                        int status = connection.getResponseCode();
                        String range = connection.getHeaderField("Content-Range");
                        var match = range == null ? null : java.util.regex.Pattern.compile("bytes \\d+-\\d+/(\\d+)").matcher(range);
                        if (match != null && match.matches()) total = Long.parseLong(match.group(1));
                        if (status != 206 || total < 0) {
                            System.err.println("CLOUD_DIRECT_MEDIA not a ranged file status=" + status);
                            return null;
                        }
                        try (InputStream body = connection.getInputStream()) { body.readNBytes(2); }
                    } finally { connection.disconnect(); }
                    // The plugin may still be finishing the upstream request when our two bytes arrive.
                    for (int wait = 0; wait < 50 && HttpDiagnostics.capturedMedia() == null; wait++) Thread.sleep(100);
                    HttpDiagnostics.MediaRequest media = HttpDiagnostics.capturedMedia();
                    if (media != null && (total < 0 || media.length == total)) {
                        System.err.println("CLOUD_DIRECT_MEDIA length=" + media.length + " probe=" + probe);
                        return new JSONObject().put("url", media.url).put("headers", new JSONObject(media.headers)).put("length", media.length).toString();
                    }
                }
                System.err.println("CLOUD_DIRECT_MEDIA unavailable");
                return null;
            } finally { HttpDiagnostics.captureMedia(false); }
        }
    }

    /** Hands a media or drive request to the plugin's proxy and streams its answer back. */
    private void relay(com.sun.net.httpserver.HttpExchange exchange, String resource, String method) throws Exception {
        if ((!resource.equals("media") || proxy == null) && (!resource.startsWith("drive/") || driveProxy == null)) { exchange.sendResponseHeaders(404, -1); return; }
        Map<String,String> params = new HashMap<>();
        String query = exchange.getRequestURI().getRawQuery();
        if (query != null) for (String pair : query.split("&")) {
            String[] parts = pair.split("=", 2);
            params.put(URLDecoder.decode(parts[0], StandardCharsets.UTF_8), parts.length == 2 ? URLDecoder.decode(parts[1], StandardCharsets.UTF_8) : "");
        }
        Map<String,String> headers = new HashMap<>();
        exchange.getRequestHeaders().forEach((key, values) -> headers.put(key.toLowerCase(Locale.ROOT), String.join(",", values)));
        touch();
        String asked = headers.get("range");
        var wanted = asked == null ? null : java.util.regex.Pattern.compile("bytes=(\\d+)-(\\d*)").matcher(asked);
        if (wanted != null && !wanted.matches()) wanted = null;
        Object[] response = invoke(resource, params, headers);
        if (wanted != null && !wanted.group(2).isEmpty() && misanswered(response, wanted.group(1))) {
            // FTY's Quark proxy skips an 8-byte prefix at the start of a range but not at its end, so a short range
            // such as AVPlayer's 0-1 probe never starts. Android players ask for open ranges; so do we, and stop at
            // the end we wanted.
            try { ((InputStream) response[2]).close(); } catch (IOException ignored) { }
            headers.put("range", "bytes=" + wanted.group(1) + "-");
            response = invoke(resource, params, headers);
        }
        if (response == null || response.length < 3 || !(response[0] instanceof Number) || !(response[2] instanceof InputStream)) {
            exchange.sendResponseHeaders(502, -1); return;
        }
        try (InputStream body = (InputStream) response[2]) {
            exchange.getResponseHeaders().set("Content-Type", String.valueOf(response[1]));
            long length = -1;
            if (response.length > 3 && response[3] instanceof Map<?,?> responseHeaders) {
                for (var entry : responseHeaders.entrySet()) {
                    String key = String.valueOf(entry.getKey());
                    String value = String.valueOf(entry.getValue());
                    if (key.equalsIgnoreCase("content-length")) {
                        try { length = Math.max(-1, Long.parseLong(value)); } catch (NumberFormatException ignored) { }
                        continue;
                    }
                    if (Set.of("connection", "transfer-encoding").contains(key.toLowerCase(Locale.ROOT))) continue;
                    if (key.equalsIgnoreCase("location")) value = rewriteAddress(value);
                    exchange.getResponseHeaders().set(key, value);
                }
            }
            int status = ((Number)response[0]).intValue();
            // Some Android proxies call a range starting at zero "200", report the entire file's size for a small
            // range or the wrong start (FTY's says "bytes 0"). AVPlayer needs the partial-response status, the range
            // it asked for and its length, including its 0-1 probe.
            String range = exchange.getResponseHeaders().getFirst("Content-Range");
            var answered = range == null ? null : java.util.regex.Pattern.compile("bytes (\\d+)-(\\d+)/(\\d+|\\*)").matcher(range);
            if (wanted != null && (status == 206 || status == 200 && range != null)) try {
                long first = Long.parseLong(wanted.group(1)), total = -1, end = -1;
                if (answered != null && answered.matches()) {
                    if (!answered.group(3).equals("*")) total = Long.parseLong(answered.group(3));
                    end = total > 0 ? total - 1 : Long.parseLong(answered.group(2));
                } else if (first == 0 && length > 0) end = (total = length) - 1;
                long last = wanted.group(2).isEmpty() ? end : Math.min(Long.parseLong(wanted.group(2)), end);
                if (end >= 0 && first <= last) {
                    status = 206;
                    length = last - first + 1;
                    exchange.getResponseHeaders().set("Content-Range", "bytes " + first + "-" + last + "/" + (total < 0 ? "*" : total));
                }
            } catch (NumberFormatException ignored) { }
            boolean noBody = method.equals("HEAD") || status == 204 || status == 304 || length == 0;
            if (length >= 0 && noBody) exchange.getResponseHeaders().set("Content-Length", Long.toString(length));
            exchange.sendResponseHeaders(status, noBody ? -1 : length > 0 ? length : 0);
            System.err.println("CLOUD_PROXY_RESPONSE status=" + status + " length=" + length + " head=" + method.equals("HEAD"));
            if (!noBody) {
                byte[] buffer = new byte[64 * 1024]; int count;
                long remaining = length;
                while (remaining != 0 && (count = body.read(buffer, 0, remaining < 0 ? buffer.length : (int)Math.min(buffer.length, remaining))) != -1) {
                    exchange.getResponseBody().write(buffer, 0, count); touch();
                    if (remaining > 0) remaining -= count;
                }
                System.err.println("CLOUD_PROXY_COMPLETE remaining=" + remaining);
            }
        }
    }

    private Object[] invoke(String resource, Map<String,String> params, Map<String,String> headers) throws Exception {
        if (resource.startsWith("drive/")) {
            String route = resource.substring("drive".length());
            if (route.startsWith("/proxy")) route = route.substring("/proxy".length());
            return driveProxy.invoke(new HashMap<>(params), route, headers);
        }
        Map<String,String> request = new HashMap<>(params);
        request.putAll(headers);
        return proxy.invoke(request);
    }

    /** A 206 answer whose Content-Range is missing, malformed or starts somewhere other than the range asked for. */
    private static boolean misanswered(Object[] response, String first) {
        if (response == null || response.length < 4 || !(response[0] instanceof Number status) || status.intValue() != 206
                || !(response[2] instanceof InputStream) || !(response[3] instanceof Map<?,?> answer)) return false;
        for (var entry : answer.entrySet())
            if (String.valueOf(entry.getKey()).equalsIgnoreCase("content-range"))
                return !String.valueOf(entry.getValue()).matches("bytes " + first + "-\\d+/(\\d+|\\*)");
        return true;
    }

    private static HttpServer standard;

    /**
     * TVBox serves plugin proxies at 127.0.0.1:9978 (or the next free port up to 9999), and plugins
     * find it by asking /proxy?do=ck for "ok". Without it they build addresses with port -1 inside
     * playlists and parse URLs that nothing can rewrite. Requests go to the active source's proxy.
     */
    private static synchronized void startStandardPort() {
        if (standard != null) return;
        for (int port = 9978; port <= 9999; port++) {
            HttpServer candidate;
            try { candidate = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 16); }
            catch (IOException busy) { continue; }
            candidate.setExecutor(Executors.newFixedThreadPool(4, r -> { Thread t = new Thread(r, "tvbox-proxy"); t.setDaemon(true); return t; }));
            candidate.createContext("/proxy", exchange -> {
                try {
                    String method = exchange.getRequestMethod();
                    if (exchange.getRequestHeaders().containsKey("Origin")) { exchange.sendResponseHeaders(403, -1); return; }
                    if (!method.equals("GET") && !method.equals("HEAD")) { exchange.sendResponseHeaders(405, -1); return; }
                    String query = exchange.getRequestURI().getRawQuery();
                    if (query != null && (query.equals("do=ck") || query.startsWith("do=ck&"))) {
                        byte[] ok = "ok".getBytes(StandardCharsets.UTF_8);
                        exchange.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
                        exchange.sendResponseHeaders(200, method.equals("HEAD") ? -1 : ok.length);
                        if (!method.equals("HEAD")) exchange.getResponseBody().write(ok);
                        return;
                    }
                    CloudDriveBridge bridge = current;
                    if (bridge == null) { exchange.sendResponseHeaders(404, -1); return; }
                    bridge.relay(exchange, "media", method);
                } catch (Exception error) {
                    System.err.println("CLOUD_PROXY_ERROR " + error.getClass().getSimpleName());
                    try { exchange.sendResponseHeaders(502, -1); } catch (IOException ignored) { }
                } finally { exchange.close(); }
            });
            // The dispatcher thread inherits daemon status from its starter; this server lives for
            // the whole process and must not keep a plugin process alive after its request.
            Thread starter = new Thread(candidate::start, "tvbox-proxy-start");
            starter.setDaemon(true);
            starter.start();
            try { starter.join(); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            standard = candidate;
            return;
        }
    }
    private long lastTouch;
    private synchronized void touch() {
        long now = System.nanoTime();
        if (lastTouch != 0 && now - lastTouch < 1_000_000_000L) return;
        try { Files.writeString(activity, "active"); lastTouch = now; } catch (IOException ignored) { }
    }
    private String base() { return "http://127.0.0.1:" + server.getAddress().getPort() + "/" + capability + "/"; }
    public static String getUrl() {
        CloudDriveBridge bridge = bridge();
        if (bridge == null) throw new IllegalStateException("Plugin proxy is not initialized");
        return bridge.base() + "media";
    }
    /** Newer spider bases call Proxy.getProxyUrlDo("x") for the local proxy with do=x; merged JARs may lack it. */
    public static String getProxyUrlDo(String value) { return getUrl() + "?do=" + value; }
    public static String getOwnProxyUrl() { return getOwnProxyUrl(""); }
    public static String getOwnProxyUrl(String name) {
        CloudDriveBridge bridge = bridge();
        if (bridge == null) throw new IllegalStateException("Plugin proxy is not initialized");
        return bridge.base() + "drive/" + (name.isEmpty() ? "" : "proxy/" + name + "/");
    }
    public void setDriveProxy(ClassLoader loader) {
        driveProxy = (params, path, headers) -> (Object[])loader.loadClass("com.github.catvod.spider.ProxyOrigin")
            .getMethod("proxyDrive", Map.class, String.class, Map.class, String.class, String.class)
            .invoke(null, params, path, headers, "", "");
    }
    public void setDriveProxy(DriveProxy value) { driveProxy = value; }
    public void setProxy(Proxy value) { proxy = value; }

    /** The drive cookies (quarkCookie, ucCookie, baiduCookie) the app holds a sign-in in, with their digests. */
    private volatile Map<String, String> appAccounts = Map.of();
    /** The source's context, whose Wex preferences OwnDriveSignIn reads after the plugin signs in. */
    private volatile android.content.Context context;
    public void appAccounts(JSONObject accounts) { appAccounts(accounts, null); }
    public void appAccounts(JSONObject accounts, android.content.Context value) {
        var held = new HashMap<String, String>();
        for (String key : List.of("quarkCookie", "ucCookie", "baiduCookie")) {
            String cookie = accounts == null ? "" : accounts.optString(key).trim();
            if (!cookie.isEmpty()) held.put(key, digest(cookie));
        }
        appAccounts = Map.copyOf(held);
        context = value;
    }
    boolean hasAppAccount(String field) { return appAccounts.containsKey(field); }
    /** The digest of the app's sign-in in this field, or "" without one. */
    String appAccountDigest(String field) { return appAccounts.getOrDefault(field, ""); }
    android.content.Context context() { return context; }

    /** The plugin's own /proxy answer to these parameters as text, or null when it has no proxy or no body. */
    String proxyText(Map<String,String> params) throws Exception {
        Proxy handler = proxy;
        if (handler == null) return null;
        Object[] answer = handler.invoke(new HashMap<>(params));
        if (answer == null || answer.length < 3 || !(answer[2] instanceof InputStream body)) return null;
        try (body) { return new String(body.readAllBytes(), StandardCharsets.UTF_8); }
    }

    public String extension(String original, JSONObject accounts) throws Exception {
        if (accounts == null || original == null || !original.trim().startsWith("{")) return original;
        JSONObject ext = new JSONObject(original);
        boolean configured = false;
        for (String key : List.of("quarkCookie", "ucCookie", "ucToken", "token")) if (!accounts.optString(key).isBlank()) configured = true;
        if (!configured) return original;
        if (ext.has("Cloud-drive")) {
            files.put("accounts", accounts.toString().getBytes(StandardCharsets.UTF_8));
            ext.put("Cloud-drive", base() + "accounts");
        }
        for (var entry : Map.of("cookie", "quarkCookie", "uc_cookie", "ucCookie", "token", "token").entrySet()) {
            String value = accounts.optString(entry.getValue());
            if (ext.has(entry.getKey()) && !value.isBlank()) {
                files.put(entry.getKey(), value.getBytes(StandardCharsets.UTF_8));
                ext.put(entry.getKey(), base() + entry.getKey());
            }
        }
        return ext.toString();
    }
    /**
     * Pan spiders of the csp_Config family read raw drive cookies from {@code files/.quark}, {@code .uc}
     * and {@code .baidu}. Their config center fills these from a phone through a LAN QR code this host
     * can't serve, and with no cookie they open an Android QR dialog, so the app's accounts go there
     * before the spider starts. A file holding JSON belongs to another plugin's format and stays.
     */
    public static void seedDriveCookies(JSONObject accounts, Path files) {
        if (accounts == null) return;
        for (var entry : Map.of(".quark", "quarkCookie", ".uc", "ucCookie", ".baidu", "baiduCookie").entrySet()) {
            String cookie = accounts.optString(entry.getValue()).trim();
            if (cookie.isEmpty()) continue;
            Path file = files.resolve(entry.getKey());
            try {
                String saved = Files.isRegularFile(file) ? Files.readString(file, StandardCharsets.UTF_8).trim() : "";
                if (saved.equals(cookie) || saved.startsWith("{")) continue;
                Files.createDirectories(files);
                Files.writeString(file, cookie, StandardCharsets.UTF_8);
            } catch (IOException unwritable) {
                System.err.println("CLOUD_ACCOUNT_SEED_FAILED " + entry.getKey());
            }
        }
    }

    /** The SharedPreferences where the Wex family (王二小's MyPan, 玩偶 and the other AiNew drive lines) keeps sign-ins. */
    public static final String WEX_PREFERENCES = "NewWexFnw_preferences";

    /** The Wex preferences that hold the drives the app signs in to, and the app's account field for each. */
    static final Map<String, String> WEX_APP_KEYS = Map.of("Wex_quark_cookie", "quarkCookie", "Wex_ucpan_cookie", "ucCookie", "Wex_baidu_cookie", "baiduCookie");
    /** In the shared {@code wexPreferences}: the digest of the app sign-in that a plugin sign-in replaced. */
    static final String WEX_REPLACED = "yingxia.replaced.";

    /**
     * Wex spiders read raw drive cookies from {@code Wex_quark_cookie}, {@code Wex_ucpan_cookie} and
     * {@code Wex_baidu_cookie} in {@link #WEX_PREFERENCES}, which only their config center fills. Each app
     * sign-in goes there once (a digest marks what was given), so the plugin's own cookie refreshes stay
     * until the user signs in again. A sign-in one Wex source made through its own code
     * ({@code wexPreferences}, see OwnDriveSignIn) reaches every source the same way, also after a new jar
     * version; one that replaced an app sign-in the plugin refused holds until the app signs in again.
     */
    public static void seedWexCookies(JSONObject accounts, android.content.Context context) {
        if (accounts == null) return;
        var values = new java.util.TreeMap<String, String>();
        for (var entry : WEX_APP_KEYS.entrySet()) {
            String cookie = accounts.optString(entry.getValue()).trim();
            if (!cookie.isEmpty()) values.put(entry.getKey(), cookie);
        }
        JSONObject shared = accounts.optJSONObject("wexPreferences");
        if (shared != null) for (var keys = shared.keys(); keys.hasNext(); ) {
            String key = String.valueOf(keys.next()), value = shared.optString(key);
            if (!key.startsWith("Wex_") || value.isEmpty()) continue;
            String field = WEX_APP_KEYS.get(key);
            if (field != null && !digest(accounts.optString(field).trim()).equals(shared.optString(WEX_REPLACED + key))) continue;
            values.put(key, value);
        }
        if (values.isEmpty()) return;
        var preferences = context.getSharedPreferences(WEX_PREFERENCES, 0);
        var editor = preferences.edit();
        boolean changed = false;
        for (var entry : values.entrySet()) {
            String given = "yingxia." + entry.getKey(), digest = digest(entry.getValue());
            if (digest.equals(preferences.getString(given, ""))) continue;
            editor.putString(entry.getKey(), entry.getValue()).putString(given, digest);
            changed = true;
        }
        if (changed && !editor.commit()) System.err.println("CLOUD_ACCOUNT_SEED_FAILED " + WEX_PREFERENCES);
    }

    static String digest(String text) {
        try { return HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8))); }
        catch (java.security.NoSuchAlgorithmException unavailable) { throw new IllegalStateException(unavailable); }
    }

    /** Where the plugin offers the app a sign-in only it has (see syncFtyAccounts). */
    public static final String PLUGIN_ACCOUNTS = "plugin-accounts.json";

    /**
     * FTY keeps its Baidu sign-in in {@code files/mybd_cookie} and its Aliyun one in
     * {@code files/ali_user}, both guard-encrypted JSON ({@code bduss}, {@code stoken}, {@code ptoken};
     * {@code refresh_token}). The app's Baidu account goes in before the spider starts (Aliyun reaches
     * it as the Cloud-drive {@code token}). A sign-in only the plugin has, made through its own QR code
     * before the app kept one, is offered back in the session folder for the app to keep.
     */
    public void syncFtyAccounts(JSONObject accounts, java.nio.file.Path files, java.nio.file.Path folder) {
        var offer = new JSONObject();
        try {
            String cookie = accounts == null ? "" : accounts.optString("baiduCookie");
            var saved = files.resolve("mybd_cookie");
            var fields = new java.util.HashMap<String, String>();
            for (String part : cookie.split(";")) {
                int split = part.indexOf('=');
                if (split > 0) fields.put(part.substring(0, split).trim(), part.substring(split + 1).trim());
            }
            String bduss = fields.getOrDefault("BDUSS", "");
            JSONObject current = readFty(saved);
            if (!bduss.isEmpty()) {
                if (current == null || !bduss.equals(current.optString("bduss"))) {
                    var value = new JSONObject().put("devuid", current == null ? "" : current.optString("devuid"))
                        .put("stoken", fields.getOrDefault("STOKEN", "")).put("bduss", bduss).put("ptoken", fields.getOrDefault("PTOKEN", ""));
                    Files.createDirectories(files);
                    Files.writeString(saved, com.github.catvod.spider.DexNative.encrypt(value.toString()), StandardCharsets.UTF_8);
                    System.err.println("CLOUD_ACCOUNT_RESTORED baidu");
                }
            } else if (current != null && !current.optString("bduss").isEmpty()) {
                var value = new StringBuilder("BDUSS=").append(current.optString("bduss"));
                if (!current.optString("ptoken").isEmpty()) value.append("; PTOKEN=").append(current.optString("ptoken"));
                if (!current.optString("stoken").isEmpty()) value.append("; STOKEN=").append(current.optString("stoken"));
                offer.put("baiduCookie", value.toString());
            }
            if (accounts == null || accounts.optString("token").isBlank()) {
                JSONObject aliyun = readFty(files.resolve("ali_user"));
                String token = aliyun == null ? "" : aliyun.optString("refresh_token");
                if (token.length() == 32) offer.put("token", token);
            }
            var offered = folder.resolve(PLUGIN_ACCOUNTS);
            if (offer.length() > 0) {
                Files.writeString(offered, offer.toString(), StandardCharsets.UTF_8);
                System.err.println("CLOUD_ACCOUNT_OFFERED " + offer.names());
            } else Files.deleteIfExists(offered);
        } catch (Throwable unavailable) {
            System.err.println("CLOUD_ACCOUNT_SYNC_FAILED " + unavailable);
        }
    }

    private static JSONObject readFty(java.nio.file.Path file) {
        try {
            if (!Files.isRegularFile(file)) return null;
            String plain = com.github.catvod.spider.DexNative.decrypt(Files.readString(file, StandardCharsets.UTF_8).trim());
            return plain == null || !plain.trim().startsWith("{") ? null : new JSONObject(plain);
        } catch (Throwable unreadable) { return null; }
    }

    /** Restore the two values FTY normally saves after its Android QR dialog succeeds. */
    public boolean restoreFtyQuarkAccount(JSONObject accounts, Class<?> spiderClass) throws Exception {
        if (accounts == null) return false;
        String cookie = accounts.optString("quarkCookie"), ticket = accounts.optString("quarkServiceTicket");
        if (cookie.isBlank() || ticket.isBlank()) return false;
        Class<?> pan = spiderClass;
        while (pan != null && !pan.getName().equals("com.github.catvod.spider.Pan")) pan = pan.getSuperclass();
        if (pan == null) return false;
        FtyQuarkAccount account = null;
        try {
            for (var field : pan.getDeclaredFields())
                if (field.getType().getName().equals("com.github.catvod.spider.Cloud_quark")) account = ftyQuarkAccount(field.getType());
        } catch (ReflectiveOperationException | LinkageError | IOException unreadable) { account = null; }
        if (account == null) { System.err.println("CLOUD_ACCOUNT_UNSUPPORTED quark"); return false; }
        // Never alter verification methods or success flags: the plugin validates the cookie.
        Object instance = account.singleton().invoke(null);
        account.web().set(instance, cookie); account.mobile().set(instance, ticket);
        System.err.println("CLOUD_ACCOUNT_RESTORED quark");
        return true;
    }

    /** FTY's Quark account singleton and the fields that hold its web cookie and mobile ticket. */
    record FtyQuarkAccount(java.lang.reflect.Method singleton, java.lang.reflect.Field web, java.lang.reflect.Field mobile) {}

    /**
     * FTY renames its Quark account class, and lately its members too, in most releases (merge.xU,
     * Z, N0, then k), so the account is found by what its code does, not by name. Cloud_quark keeps
     * its name and fetches the account through exactly one static singleton. In the account class,
     * the sign-in response handler {@code (okhttp3.Response, String) -> boolean} stores the web cookie
     * and the static {@code (account, String)} setter stores the mobile ticket. Each must store exactly
     * one public String field, or nothing is restored. Only these two classes are read.
     */
    static FtyQuarkAccount ftyQuarkAccount(Class<?> quark) throws ReflectiveOperationException, IOException {
        byte[] code = classBytes(quark);
        if (code == null) return null;
        var singletons = new HashSet<String>();
        new ClassReader(code).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override public void visitMethodInsn(int opcode, String owner, String method, String type, boolean isInterface) {
                        if (opcode == Opcodes.INVOKESTATIC && type.equals("()L" + owner + ";") && owner.startsWith("com/github/catvod/spider/merge/"))
                            singletons.add(owner + "." + method);
                    }
                };
            }
        }, ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
        if (singletons.size() != 1) return null;
        String call = singletons.iterator().next(), owner = call.substring(0, call.lastIndexOf('.'));
        Class<?> type = Class.forName(owner.replace('/', '.'), false, quark.getClassLoader());
        code = classBytes(type);
        if (code == null) return null;
        var web = new HashSet<String>(); var mobile = new HashSet<String>();
        new ClassReader(code).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                boolean instance = (access & Opcodes.ACC_STATIC) == 0;
                Set<String> stored = instance && descriptor.equals("(Lokhttp3/Response;Ljava/lang/String;)Z") ? web
                    : !instance && descriptor.equals("(L" + owner + ";Ljava/lang/String;)V") ? mobile : null;
                return stored == null ? null : new MethodVisitor(Opcodes.ASM9) {
                    @Override public void visitFieldInsn(int opcode, String fieldOwner, String field, String fieldType) {
                        if (opcode == Opcodes.PUTFIELD && fieldOwner.equals(owner) && fieldType.equals("Ljava/lang/String;")) stored.add(field);
                    }
                };
            }
        }, ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
        if (web.size() != 1 || mobile.size() != 1 || web.equals(mobile)) return null;
        var singleton = type.getMethod(call.substring(call.lastIndexOf('.') + 1));
        var webField = type.getField(web.iterator().next()); var mobileField = type.getField(mobile.iterator().next());
        if (!java.lang.reflect.Modifier.isStatic(singleton.getModifiers()) || singleton.getReturnType() != type
            || java.lang.reflect.Modifier.isStatic(webField.getModifiers()) || java.lang.reflect.Modifier.isStatic(mobileField.getModifiers())) return null;
        return new FtyQuarkAccount(singleton, webField, mobileField);
    }

    private static byte[] classBytes(Class<?> type) throws IOException {
        ClassLoader loader = type.getClassLoader();
        if (loader == null) return null;
        try (InputStream input = loader.getResourceAsStream(type.getName().replace('.', '/') + ".class")) {
            return input == null ? null : input.readAllBytes();
        }
    }

    /** The Cloud-based Wogg family accepts inline cookies under different keys than FTY. */
    public String cloudExtension(String original, JSONObject accounts, Class<?> spiderClass) throws Exception {
        if (accounts == null) return original;
        Class<?> cloud = spiderClass;
        while (cloud != null && !cloud.getName().equals("com.github.catvod.spider.Cloud")) cloud = cloud.getSuperclass();
        if (cloud == null) return original;
        // Scope the adapter to the inspected contract; do not send accounts to unrelated spiders.
        try {
            if (!cloud.getField("a").getType().getName().equals("com.github.catvod.spider.Quark")
                || !cloud.getField("c").getType().getName().equals("com.github.catvod.spider.UC")) return original;
        } catch (NoSuchFieldException absent) { return original; }
        JSONObject ext = original == null || original.isBlank() ? new JSONObject() : new JSONObject(original);
        for (var entry : Map.of("cookie", "quarkCookie", "uccookie", "ucCookie", "token", "token").entrySet()) {
            String value = accounts.optString(entry.getValue()).trim();
            if (!value.isEmpty()) ext.put(entry.getKey(), value);
        }
        return ext.toString();
    }

    public String rewriteAddress(String address) {
        for (int port : ports) {
            String prior = "http://127.0.0.1:" + port + "/" + capability + "/";
            if (address.startsWith(prior)) return base() + address.substring(prior.length());
        }
        // Preserve Bili's dedicated progressive-MP4 resolver and plain HLS unwrapping.
        if (address.contains("do=bili") || address.contains("do=m3u8")) return address;
        if (address.matches("^http://(127\\.0\\.0\\.1|localhost)(:-?\\d+)?/proxy\\?.*")) {
            return base() + "media?" + address.substring(address.indexOf('?') + 1);
        }
        return address;
    }
    public String playback(String text) throws Exception {
        ensureAvailable();
        JSONObject result = new JSONObject(text);
        Object value = result.opt("url");
        if (value instanceof String address) result.put("url", rewriteAddress(address));
        else if (value instanceof JSONArray values) for (int i = 1; i < values.length(); i += 2) {
            Object item = values.get(i); if (item instanceof String address) values.put(i, rewriteAddress(address));
        }
        return result.toString();
    }
    /** Sources sharing one plugin runtime each keep a bridge; the running request selects its own. */
    public void activate() { current = this; active.set(this); }
    public static void deactivate() { active.remove(); }
    public static void closeCurrent() { if (current != null) current.close(); }
    @Override public synchronized void close() { closed = true; server.stop(0); workers.shutdownNow(); if (current == this) current = null; }
}
