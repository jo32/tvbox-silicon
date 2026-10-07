package com.tencent.smtt.sdk;

import android.content.Context;
import java.util.Map;

/**
 * Apple platforms have no X5 page engine. Loads complete without content: clients still get
 * onPageFinished and scripts evaluate to null, so plugins fail fast instead of waiting forever.
 * Like X5's own class it is a FrameLayout, so plugin classes that add it to a layout still verify.
 */
public class WebView extends android.widget.FrameLayout {
    private final WebSettings settings = new WebSettings();
    private volatile WebViewClient client = new WebViewClient();
    private volatile WebChromeClient chromeClient;
    private volatile String url;

    public WebView(Context context) { super(context); }
    public WebView(Context context, android.util.AttributeSet attributes) { super(context, attributes); }

    public WebSettings getSettings() { return settings; }
    public void setWebViewClient(WebViewClient value) { client = value == null ? new WebViewClient() : value; }
    public void setWebChromeClient(WebChromeClient value) { chromeClient = value; }
    public String getUrl() { return url; }

    public void loadUrl(String address) { loadUrl(address, null); }
    public void loadUrl(String address, Map<String, String> headers) {
        url = address;
        Thread finish = new Thread(() -> {
            try { client.onPageFinished(this, address); } catch (Throwable ignored) { }
        }, "x5-page");
        finish.setDaemon(true);
        finish.start();
    }
    public void evaluateJavascript(String script, ValueCallback<String> callback) {
        if (callback == null) return;
        Thread result = new Thread(() -> {
            try { callback.onReceiveValue("null"); } catch (Throwable ignored) { }
        }, "x5-script");
        result.setDaemon(true);
        result.start();
    }
    public void addJavascriptInterface(Object target, String name) { }
    public void removeJavascriptInterface(String name) { }
    public void setInitialScale(int scale) { }
    public void setScrollBarStyle(int style) { }
    public void stopLoading() { }
    public void reload() { }
    public void clearCache(boolean includeDiskFiles) { }
    public void clearHistory() { }
    public void onPause() { }
    public void onResume() { }
    public void destroy() { }
}
