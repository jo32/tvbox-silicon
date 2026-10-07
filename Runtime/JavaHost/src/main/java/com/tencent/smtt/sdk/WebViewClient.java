package com.tencent.smtt.sdk;

import com.tencent.smtt.export.external.interfaces.SslError;
import com.tencent.smtt.export.external.interfaces.SslErrorHandler;
import com.tencent.smtt.export.external.interfaces.WebResourceRequest;
import com.tencent.smtt.export.external.interfaces.WebResourceResponse;

public class WebViewClient {
    public boolean shouldOverrideUrlLoading(WebView view, String url) { return false; }
    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) { return false; }
    public WebResourceResponse shouldInterceptRequest(WebView view, String url) { return null; }
    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) { return null; }
    public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) { }
    public void onPageFinished(WebView view, String url) { }
    public void onLoadResource(WebView view, String url) { }
    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) { }
    public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) { if (handler != null) handler.cancel(); }
}
