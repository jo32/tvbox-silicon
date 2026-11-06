package android.webkit;

import java.net.URI;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** The web view's cookie jar: cookies plugins set by host (and parent domains), read back as "a=b; c=d". */
public class CookieManager {
    private static final CookieManager INSTANCE = new CookieManager();
    /** host → (name → cookie text "name=value") */
    private final Map<String, Map<String, String>> jar = new ConcurrentHashMap<>();
    private volatile boolean accept = true;

    protected CookieManager() { }
    public static CookieManager getInstance() { return INSTANCE; }
    public static boolean allowFileSchemeCookies() { return false; }
    public static void setAcceptFileSchemeCookies(boolean accept) { }
    public void setAcceptCookie(boolean value) { accept = value; }
    public boolean acceptCookie() { return accept; }
    public void setAcceptThirdPartyCookies(WebView view, boolean accept) { }
    public boolean acceptThirdPartyCookies(WebView view) { return true; }

    private static String host(String url) {
        if (url == null) return null;
        try { String host = URI.create(url.contains("://") ? url : "http://" + url).getHost(); return host == null ? null : host.toLowerCase(Locale.ROOT); }
        catch (IllegalArgumentException broken) { return null; }
    }
    public void setCookie(String url, String value) {
        String host = host(url);
        if (host == null || value == null) return;
        String domain = host;
        String[] parts = value.split(";");
        for (int i = 1; i < parts.length; i++) {
            String attribute = parts[i].trim();
            if (attribute.regionMatches(true, 0, "domain=", 0, 7)) {
                String d = attribute.substring(7).trim().toLowerCase(Locale.ROOT);
                if (d.startsWith(".")) d = d.substring(1);
                if (!d.isEmpty() && (host.equals(d) || host.endsWith("." + d))) domain = d;
            }
        }
        String pair = parts[0].trim();
        int eq = pair.indexOf('=');
        String name = eq < 0 ? pair : pair.substring(0, eq).trim();
        if (name.isEmpty()) return;
        boolean expired = false;
        for (int i = 1; i < parts.length; i++) { String a = parts[i].trim().toLowerCase(Locale.ROOT); if (a.equals("max-age=0") || a.startsWith("max-age=-")) expired = true; }
        Map<String, String> cookies = jar.computeIfAbsent(domain, key -> java.util.Collections.synchronizedMap(new LinkedHashMap<>()));
        if (expired) cookies.remove(name); else cookies.put(name, pair);
    }
    public void setCookie(String url, String value, ValueCallback<Boolean> callback) { setCookie(url, value); if (callback != null) callback.onReceiveValue(true); }
    public String getCookie(String url) {
        String host = host(url);
        if (host == null) return null;
        Map<String, String> found = new LinkedHashMap<>();
        for (String domain = host; domain != null; domain = domain.indexOf('.') < 0 ? null : domain.substring(domain.indexOf('.') + 1)) {
            Map<String, String> cookies = jar.get(domain);
            if (cookies != null) synchronized (cookies) { for (var e : cookies.entrySet()) found.putIfAbsent(e.getKey(), e.getValue()); }
        }
        return found.isEmpty() ? null : String.join("; ", found.values());
    }
    public boolean hasCookies() { return jar.values().stream().anyMatch(m -> !m.isEmpty()); }
    public void removeAllCookie() { jar.clear(); }
    public void removeAllCookies(ValueCallback<Boolean> callback) { boolean had = hasCookies(); jar.clear(); if (callback != null) callback.onReceiveValue(had); }
    public void removeSessionCookie() { }
    public void removeSessionCookies(ValueCallback<Boolean> callback) { if (callback != null) callback.onReceiveValue(false); }
    public void removeExpiredCookie() { }
    public void flush() { }
}
