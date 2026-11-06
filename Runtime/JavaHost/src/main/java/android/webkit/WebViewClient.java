package android.webkit;

/** What a web view tells its owner. Nothing calls these here: this host has no browser engine. */
public class WebViewClient {
    public static final int ERROR_UNKNOWN = -1, ERROR_HOST_LOOKUP = -2, ERROR_CONNECT = -6, ERROR_TIMEOUT = -8, ERROR_UNSUPPORTED_SCHEME = -10;
    public WebViewClient() { }
    public boolean shouldOverrideUrlLoading(WebView view, String url) { return false; }
    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) { return shouldOverrideUrlLoading(view, request.getUrl() == null ? null : request.getUrl().toString()); }
    public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) { }
    public void onPageFinished(WebView view, String url) { }
    public void onLoadResource(WebView view, String url) { }
    public void onPageCommitVisible(WebView view, String url) { }
    public WebResourceResponse shouldInterceptRequest(WebView view, String url) { return null; }
    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) { return shouldInterceptRequest(view, request.getUrl() == null ? null : request.getUrl().toString()); }
    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) { }
    public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse errorResponse) { }
    public void onFormResubmission(WebView view, android.os.Message dontResend, android.os.Message resend) { }
    public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) { }
    public void onScaleChanged(WebView view, float oldScale, float newScale) { }
}
