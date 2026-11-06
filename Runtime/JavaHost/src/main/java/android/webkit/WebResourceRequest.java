package android.webkit;

public interface WebResourceRequest {
    android.net.Uri getUrl();
    boolean isForMainFrame();
    boolean isRedirect();
    boolean hasGesture();
    String getMethod();
    java.util.Map<String, String> getRequestHeaders();
}
