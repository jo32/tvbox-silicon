package android.webkit;

import android.content.Context;
import java.util.Map;

/**
 * A web view without a browser engine: plugins may create one to read its default user agent or to load a
 * page, but no page loads here, so its client never hears of one (as with a page that never answers).
 * When it is shown in a plugin window, the app gets the page's address to open.
 */
public class WebView extends android.widget.FrameLayout {
    public static final int RENDERER_PRIORITY_IMPORTANT = 2;
    private final WebSettings settings = new WebSettings();
    private WebViewClient client = new WebViewClient();
    private WebChromeClient chrome;
    private String url, title;

    public WebView(Context context) { super(context); }
    public WebView(Context context, android.util.AttributeSet attrs) { super(context); }
    public WebView(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public static void setWebContentsDebuggingEnabled(boolean enabled) { }
    public static void setDataDirectorySuffix(String suffix) { }
    public static String findAddress(String address) { return null; }
    public WebSettings getSettings() { return settings; }
    public void setWebViewClient(WebViewClient value) { client = value == null ? new WebViewClient() : value; }
    public WebViewClient getWebViewClient() { return client; }
    public void setWebChromeClient(WebChromeClient value) { chrome = value; }
    public WebChromeClient getWebChromeClient() { return chrome; }
    public void loadUrl(String value) { url = value; }
    public void loadUrl(String value, Map<String, String> headers) { url = value; }
    public void postUrl(String value, byte[] body) { url = value; }
    public void loadData(String data, String mimeType, String encoding) { url = "about:blank"; }
    public void loadDataWithBaseURL(String baseUrl, String data, String mimeType, String encoding, String historyUrl) { url = baseUrl == null ? "about:blank" : baseUrl; }
    public void evaluateJavascript(String script, ValueCallback<String> callback) { if (callback != null) post(() -> callback.onReceiveValue("null")); }
    public void addJavascriptInterface(Object object, String name) { }
    public void removeJavascriptInterface(String name) { }
    public String getUrl() { return url; }
    public String getOriginalUrl() { return url; }
    public String getTitle() { return title; }
    public int getProgress() { return 100; }
    public void reload() { }
    public void stopLoading() { }
    public boolean canGoBack() { return false; }
    public boolean canGoForward() { return false; }
    public void goBack() { }
    public void goForward() { }
    public void clearCache(boolean includeDiskFiles) { }
    public void clearHistory() { }
    public void clearFormData() { }
    public void clearSslPreferences() { }
    public void clearMatches() { }
    public void onPause() { }
    public void onResume() { }
    public void pauseTimers() { }
    public void resumeTimers() { }
    public void destroy() { url = null; }
    public void setInitialScale(int scale) { }
    public void setDownloadListener(DownloadListener listener) { }
    public void setNetworkAvailable(boolean available) { }
    public void setRendererPriorityPolicy(int priority, boolean waivedWhenNotVisible) { }
    public void setMapTrackballToArrowKeys(boolean value) { }
    public float getScale() { return 1; }
    public int getContentHeight() { return 0; }
    public String tvboxPage() { return url == null || url.startsWith("about:") ? null : url; }
    private String shown;
    /** A web view in a plugin window: the app opens its page once, since nothing draws it here. */
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        super.tvboxDescribe(node);
        String page = tvboxPage();
        if (page != null && !page.equals(shown)) { shown = page; tvbox.runtime.PluginWindows.openLink(page); }
    }
}
