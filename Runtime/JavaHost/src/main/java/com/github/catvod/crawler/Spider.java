package com.github.catvod.crawler;
import android.content.Context;
import okhttp3.Dns;
import okhttp3.OkHttpClient;
import java.util.*;
import java.util.concurrent.TimeUnit;
/** CatVod host contract; each plugin supplies its own content implementation. */
public abstract class Spider {
    public String siteKey;
    /** FongMi's new spider SDK: the host sets these for each source (NativeProbe.createStandardSession). */
    public com.github.catvod.net.Net net;
    public com.github.catvod.utils.Local local;
    public final com.github.catvod.utils.Js js = new com.github.catvod.utils.Js();
    private final com.github.catvod.utils.Dialog dialog = new com.github.catvod.utils.Dialog();
    private static final OkHttpClient HTTP = new OkHttpClient.Builder()
        .addInterceptor(chain -> {
            var request = chain.request();
            System.err.println("HTTP " + request.url().scheme() + "://" + request.url().host() + request.url().encodedPath());
            try {
                var response = chain.proceed(request);
                System.err.println("HTTP_RESULT " + response.code());
                if (!response.isSuccessful() && !request.url().host().equals("127.0.0.1") && !request.url().host().equals("localhost")) {
                    tvbox.runtime.HttpDiagnostics.recordStatus(request.url().host(), response.code());
                }
                return response;
            } catch (Exception error) { error.printStackTrace(System.err); throw error; }
        }).connectTimeout(20, TimeUnit.SECONDS).readTimeout(25, TimeUnit.SECONDS).callTimeout(35, TimeUnit.SECONDS).build();
    public static Dns safeDns() { return Dns.SYSTEM; }
    public static OkHttpClient client() { return HTTP; }
    // FongMi's new spider SDK.
    public org.json.JSONObject dialog(org.json.JSONObject options) throws Exception { return dialog(options, null); }
    public org.json.JSONObject dialog(org.json.JSONObject options, com.github.catvod.utils.Dialog.Callback callback) throws Exception { return dialog.show(options, callback); }
    public void closeDialog() { dialog.close(); }
    public android.app.Activity getActivity() { return com.github.catvod.Runtime.activity(); }
    public String proxyUrl() { return proxyUrl(Collections.emptyMap()); }
    public String proxyUrl(Map<String, String> params) { return proxyUrl(params, true); }
    public String proxyUrl(Map<String, String> params, boolean local) {
        if (params == null) params = Collections.emptyMap();
        android.net.Uri.Builder url = android.net.Uri.parse(com.github.catvod.Proxy.getUrl(local)).buildUpon();
        url.appendQueryParameter("do", "jar");
        url.appendQueryParameter("siteKey", siteKey);
        for (Map.Entry<?, ?> entry : params.entrySet()) {
            if (!(entry.getKey() instanceof String name) || !(entry.getValue() instanceof String text)) throw new IllegalArgumentException("Proxy parameters require string keys and values");
            if (name.equals("do") || name.equals("siteKey")) throw new IllegalArgumentException("Reserved proxy parameter");
            url.appendQueryParameter(name, text);
        }
        return url.build().toString();
    }
    public String danmakuUrl(String id) { return danmakuUrl(siteKey, id); }
    public static String danmakuUrl(String siteKey, String id) {
        if (siteKey == null || siteKey.isEmpty() || id == null || id.isEmpty()) throw new IllegalArgumentException("Danmaku requires a site key and ID");
        return new android.net.Uri.Builder().scheme("spider").authority(siteKey).appendPath(id).build().toString();
    }
    public AutoCloseable danmaku(String id, java.util.function.Consumer<org.json.JSONObject> emit) throws Exception {
        throw new UnsupportedOperationException("Spider does not support live danmaku");
    }
    /** Ends the new SDK's dialogs, scripts and network calls of this source; the host calls it after destroy(). */
    public final void closeHostResources() {
        try { dialog.close(); js.close(); }
        finally { if (net != null) net.close(); }
    }

    public void init(Context context) throws Exception { }
    public void init(Context context, String extension) throws Exception { init(context); }
    public String homeContent(boolean filter) throws Exception { return ""; }
    public String homeVideoContent() throws Exception { return ""; }
    public String categoryContent(String type, String page, boolean filter, HashMap<String,String> ext) throws Exception { return ""; }
    public String detailContent(List<String> ids) throws Exception { return ""; }
    public String searchContent(String query, boolean quick) throws Exception { return ""; }
    public String searchContent(String query, boolean quick, String page) throws Exception { return searchContent(query, quick); }
    public String playerContent(String flag, String id, List<String> flags) throws Exception { return ""; }
    public String liveContent(String url) throws Exception { return ""; }
    public String action(String action) throws Exception { return ""; }
    public Object[] proxy(Map<String,String> request) throws Exception { return null; }
    public boolean manualVideoCheck() { return false; }
    public boolean isVideoFormat(String url) { return false; }
    public void destroy() { }
}
