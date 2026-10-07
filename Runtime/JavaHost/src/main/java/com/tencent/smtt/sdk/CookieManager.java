package com.tencent.smtt.sdk;

import java.net.URI;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** In-memory cookie jar keyed by host, enough for plugins that read back cookies they set. */
public class CookieManager {
    private static final CookieManager INSTANCE = new CookieManager();
    private final Map<String, Map<String, String>> cookies = new ConcurrentHashMap<>();

    public static CookieManager getInstance() { return INSTANCE; }

    private static String host(String url) {
        try { String host = URI.create(url).getHost(); return host == null ? url : host; }
        catch (IllegalArgumentException invalid) { return url; }
    }

    public void setCookie(String url, String value) {
        if (url == null || value == null) return;
        String pair = value.split(";", 2)[0];
        int split = pair.indexOf('=');
        if (split <= 0) return;
        cookies.computeIfAbsent(host(url), key -> new ConcurrentHashMap<>()).put(pair.substring(0, split).trim(), pair.substring(split + 1).trim());
    }
    public String getCookie(String url) {
        Map<String, String> values = url == null ? null : cookies.get(host(url));
        if (values == null || values.isEmpty()) return null;
        StringBuilder header = new StringBuilder();
        values.forEach((name, value) -> { if (header.length() > 0) header.append("; "); header.append(name).append('=').append(value); });
        return header.toString();
    }
    public void setAcceptCookie(boolean accept) { }
    public void setAcceptThirdPartyCookies(WebView view, boolean accept) { }
    public boolean hasCookies() { return !cookies.isEmpty(); }
    public void removeAllCookie() { cookies.clear(); }
    public void removeAllCookies(ValueCallback<Boolean> callback) { cookies.clear(); if (callback != null) callback.onReceiveValue(true); }
    public void removeSessionCookie() { }
    public void flush() { }
}
