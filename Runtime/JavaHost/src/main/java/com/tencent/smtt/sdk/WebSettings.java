package com.tencent.smtt.sdk;

/** Settings are accepted and remembered; there is no page engine for them to configure. */
public class WebSettings {
    private String userAgent = "";
    public void setUserAgentString(String value) { userAgent = value == null ? "" : value; }
    public String getUserAgentString() { return userAgent; }
    public void setJavaScriptEnabled(boolean enabled) { }
    public void setDomStorageEnabled(boolean enabled) { }
    public void setDatabaseEnabled(boolean enabled) { }
    public void setUseWideViewPort(boolean enabled) { }
    public void setSupportZoom(boolean enabled) { }
    public void setLoadWithOverviewMode(boolean enabled) { }
    public void setGeolocationEnabled(boolean enabled) { }
    public void setBuiltInZoomControls(boolean enabled) { }
    public void setAllowFileAccess(boolean enabled) { }
    public void setAllowContentAccess(boolean enabled) { }
    public void setSupportMultipleWindows(boolean enabled) { }
    public void setJavaScriptCanOpenWindowsAutomatically(boolean enabled) { }
    public void setCacheMode(int mode) { }
    public void setMixedContentMode(int mode) { }
    public void setMediaPlaybackRequiresUserGesture(boolean required) { }
    public void setBlockNetworkImage(boolean blocked) { }
    public void setLoadsImagesAutomatically(boolean enabled) { }
    public void setDefaultTextEncodingName(String name) { }
}
