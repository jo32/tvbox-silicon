package com.tencent.smtt.export.external.interfaces;

import java.io.InputStream;
import java.util.Map;

public class WebResourceResponse {
    private String mimeType, encoding, reasonPhrase;
    private int statusCode = 200;
    private Map<String, String> responseHeaders;
    private InputStream data;

    public WebResourceResponse() { }
    public WebResourceResponse(String mimeType, String encoding, InputStream data) {
        this.mimeType = mimeType; this.encoding = encoding; this.data = data;
    }
    public WebResourceResponse(String mimeType, String encoding, int statusCode, String reasonPhrase, Map<String, String> responseHeaders, InputStream data) {
        this(mimeType, encoding, data);
        this.statusCode = statusCode; this.reasonPhrase = reasonPhrase; this.responseHeaders = responseHeaders;
    }
    public String getMimeType() { return mimeType; }
    public String getEncoding() { return encoding; }
    public int getStatusCode() { return statusCode; }
    public String getReasonPhrase() { return reasonPhrase; }
    public Map<String, String> getResponseHeaders() { return responseHeaders; }
    public InputStream getData() { return data; }
    public void setMimeType(String value) { mimeType = value; }
    public void setEncoding(String value) { encoding = value; }
    public void setData(InputStream value) { data = value; }
    public void setResponseHeaders(Map<String, String> value) { responseHeaders = value; }
    public void setStatusCodeAndReasonPhrase(int code, String phrase) { statusCode = code; reasonPhrase = phrase; }
}
