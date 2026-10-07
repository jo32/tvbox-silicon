package tvbox.runtime;

import com.sun.net.httpserver.HttpServer;
import org.json.*;
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
    private final HttpServer server;
    private final ExecutorService workers = Executors.newFixedThreadPool(4, r -> { Thread t = new Thread(r, "cloud-proxy"); t.setDaemon(true); return t; });
    private final String capability = UUID.randomUUID().toString();
    private final Map<String, byte[]> files = new HashMap<>();
    private final Path activity;
    private volatile Proxy proxy;
    private final java.util.concurrent.atomic.AtomicInteger configurationReads = new java.util.concurrent.atomic.AtomicInteger();

    public CloudDriveBridge(Path cache) throws IOException {
        activity = cache.resolve("proxy-active");
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 16);
        server.setExecutor(workers);
        server.createContext("/", exchange -> {
            try {
                String path = exchange.getRequestURI().getPath();
                if (!path.startsWith("/" + capability + "/") || exchange.getRequestHeaders().containsKey("Origin")) {
                    exchange.sendResponseHeaders(403, -1); return;
                }
                String method = exchange.getRequestMethod();
                if (!method.equals("GET") && !method.equals("HEAD")) { exchange.sendResponseHeaders(405, -1); return; }
                String resource = path.substring(capability.length() + 2);
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
        server.start();
        current = this;
        startStandardPort();
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
        Object[] response;
        if (resource.startsWith("drive/")) {
            String route = resource.substring("drive".length());
            if (route.startsWith("/proxy")) route = route.substring("/proxy".length());
            response = driveProxy.invoke(params, route, headers);
        } else { params.putAll(headers); response = proxy.invoke(params); }
        if (response == null || response.length < 3 || !(response[0] instanceof Number) || !(response[2] instanceof InputStream)) {
            exchange.sendResponseHeaders(502, -1); return;
        }
        try (InputStream body = (InputStream) response[2]) {
            exchange.getResponseHeaders().set("Content-Type", String.valueOf(response[1]));
            if (response.length > 3 && response[3] instanceof Map<?,?> responseHeaders) {
                for (var entry : responseHeaders.entrySet()) {
                    String key = String.valueOf(entry.getKey());
                    if (Set.of("connection", "transfer-encoding", "content-length").contains(key.toLowerCase(Locale.ROOT))) continue;
                    String value = String.valueOf(entry.getValue());
                    if (key.equalsIgnoreCase("location")) value = rewriteAddress(value);
                    exchange.getResponseHeaders().set(key, value);
                }
            }
            int status = ((Number)response[0]).intValue();
            exchange.sendResponseHeaders(status, method.equals("HEAD") || status == 204 || status == 304 ? -1 : 0);
            if (!method.equals("HEAD")) {
                byte[] buffer = new byte[64 * 1024]; int count;
                while ((count = body.read(buffer)) != -1) { exchange.getResponseBody().write(buffer, 0, count); touch(); }
            }
        }
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
    public void setProxy(Proxy value) { proxy = value; }

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
        // Preserve Bili's dedicated progressive-MP4 resolver and plain HLS unwrapping.
        if (address.contains("do=bili") || address.contains("do=m3u8")) return address;
        if (address.matches("^http://(127\\.0\\.0\\.1|localhost)(:-?\\d+)?/proxy\\?.*")) {
            return base() + "media?" + address.substring(address.indexOf('?') + 1);
        }
        return address;
    }
    public String playback(String text) throws Exception {
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
    @Override public void close() { server.stop(0); workers.shutdownNow(); if (current == this) current = null; }
}
