package com.tencent.smtt.export.external.interfaces;

import java.util.Map;

public interface WebResourceRequest {
    android.net.Uri getUrl();
    boolean isForMainFrame();
    boolean isRedirect();
    boolean hasGesture();
    String getMethod();
    Map<String, String> getRequestHeaders();
}
