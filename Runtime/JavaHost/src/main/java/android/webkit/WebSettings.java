package android.webkit;

/** A web view's settings, kept for plugins that read them back (the user agent most often). */
public class WebSettings {
    public enum LayoutAlgorithm { NORMAL, SINGLE_COLUMN, NARROW_COLUMNS, TEXT_AUTOSIZING }
    public enum PluginState { ON, ON_DEMAND, OFF }
    public enum RenderPriority { NORMAL, HIGH, LOW }
    public enum ZoomDensity { FAR, MEDIUM, CLOSE }
    public enum TextSize { SMALLEST, SMALLER, NORMAL, LARGER, LARGEST }
    public static final int LOAD_DEFAULT = -1, LOAD_NORMAL = 0, LOAD_CACHE_ELSE_NETWORK = 1, LOAD_NO_CACHE = 2, LOAD_CACHE_ONLY = 3;
    public static final int MIXED_CONTENT_ALWAYS_ALLOW = 0, MIXED_CONTENT_NEVER_ALLOW = 1, MIXED_CONTENT_COMPATIBILITY_MODE = 2;
    /** Chrome on an Android 9 phone, which is what a TVBox web view reports. */
    static final String DEFAULT_AGENT = "Mozilla/5.0 (Linux; Android 9; TVBox Apple Host Build/PQ3A.190705.003; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.6099.230 Mobile Safari/537.36";

    private String userAgent = DEFAULT_AGENT;
    private boolean javaScript, domStorage, database, allowFileAccess = true, allowContentAccess = true, mediaGesture = true, blockImages;
    private int cacheMode = LOAD_DEFAULT, mixedContent = MIXED_CONTENT_NEVER_ALLOW, textZoom = 100;

    public static String getDefaultUserAgent(android.content.Context context) { return DEFAULT_AGENT; }
    public String getUserAgentString() { return userAgent; }
    public void setUserAgentString(String value) { userAgent = value == null || value.isEmpty() ? DEFAULT_AGENT : value; }
    public void setJavaScriptEnabled(boolean value) { javaScript = value; }
    public boolean getJavaScriptEnabled() { return javaScript; }
    public void setDomStorageEnabled(boolean value) { domStorage = value; }
    public boolean getDomStorageEnabled() { return domStorage; }
    public void setDatabaseEnabled(boolean value) { database = value; }
    public boolean getDatabaseEnabled() { return database; }
    public void setAllowFileAccess(boolean value) { allowFileAccess = value; }
    public boolean getAllowFileAccess() { return allowFileAccess; }
    public void setAllowContentAccess(boolean value) { allowContentAccess = value; }
    public boolean getAllowContentAccess() { return allowContentAccess; }
    public void setAllowFileAccessFromFileURLs(boolean value) { }
    public void setAllowUniversalAccessFromFileURLs(boolean value) { }
    public void setMediaPlaybackRequiresUserGesture(boolean value) { mediaGesture = value; }
    public boolean getMediaPlaybackRequiresUserGesture() { return mediaGesture; }
    public void setCacheMode(int value) { cacheMode = value; }
    public int getCacheMode() { return cacheMode; }
    public void setMixedContentMode(int value) { mixedContent = value; }
    public int getMixedContentMode() { return mixedContent; }
    public void setBlockNetworkImage(boolean value) { blockImages = value; }
    public boolean getBlockNetworkImage() { return blockImages; }
    public void setBlockNetworkLoads(boolean value) { }
    public void setLoadsImagesAutomatically(boolean value) { }
    public void setJavaScriptCanOpenWindowsAutomatically(boolean value) { }
    public void setSupportMultipleWindows(boolean value) { }
    public void setAppCacheEnabled(boolean value) { }
    public void setAppCachePath(String path) { }
    public void setAppCacheMaxSize(long size) { }
    public void setGeolocationEnabled(boolean value) { }
    public void setBuiltInZoomControls(boolean value) { }
    public void setDisplayZoomControls(boolean value) { }
    public void setSupportZoom(boolean value) { }
    public void setUseWideViewPort(boolean value) { }
    public void setLoadWithOverviewMode(boolean value) { }
    public void setLayoutAlgorithm(LayoutAlgorithm value) { }
    public void setPluginState(PluginState value) { }
    public void setRenderPriority(RenderPriority value) { }
    public void setDefaultZoom(ZoomDensity value) { }
    public void setTextZoom(int value) { textZoom = value; }
    public int getTextZoom() { return textZoom; }
    public void setTextSize(TextSize value) { }
    public void setDefaultTextEncodingName(String value) { }
    public void setSaveFormData(boolean value) { }
    public void setSavePassword(boolean value) { }
    public void setNeedInitialFocus(boolean value) { }
    public void setSafeBrowsingEnabled(boolean value) { }
    public void setOffscreenPreRaster(boolean value) { }
    public void setForceDark(int value) { }
}
