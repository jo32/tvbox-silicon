package android.webkit;

public class WebChromeClient {
    public WebChromeClient() { }
    public void onProgressChanged(WebView view, int newProgress) { }
    public void onReceivedTitle(WebView view, String title) { }
    public void onReceivedIcon(WebView view, android.graphics.Bitmap icon) { }
    public boolean onJsAlert(WebView view, String url, String message, JsResult result) { return false; }
    public boolean onJsConfirm(WebView view, String url, String message, JsResult result) { return false; }
    public boolean onJsPrompt(WebView view, String url, String message, String defaultValue, JsPromptResult result) { return false; }
    public boolean onConsoleMessage(ConsoleMessage message) { return false; }
    public void onCloseWindow(WebView window) { }
    public void onShowCustomView(android.view.View view, CustomViewCallback callback) { }
    public void onHideCustomView() { }
    public interface CustomViewCallback { void onCustomViewHidden(); }
}
