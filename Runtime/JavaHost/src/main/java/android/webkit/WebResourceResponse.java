package android.webkit;

import java.io.InputStream;
import java.util.Map;

public class WebResourceResponse {
    private String mimeType, encoding, reason;
    private int status = 200;
    private Map<String, String> headers;
    private InputStream data;
    public WebResourceResponse(String mimeType, String encoding, InputStream data) { this.mimeType = mimeType; this.encoding = encoding; this.data = data; }
    public WebResourceResponse(String mimeType, String encoding, int statusCode, String reasonPhrase, Map<String, String> responseHeaders, InputStream data) {
        this(mimeType, encoding, data); status = statusCode; reason = reasonPhrase; headers = responseHeaders;
    }
    public String getMimeType() { return mimeType; }
    public void setMimeType(String value) { mimeType = value; }
    public String getEncoding() { return encoding; }
    public void setEncoding(String value) { encoding = value; }
    public int getStatusCode() { return status; }
    public String getReasonPhrase() { return reason; }
    public void setStatusCodeAndReasonPhrase(int code, String phrase) { status = code; reason = phrase; }
    public Map<String, String> getResponseHeaders() { return headers; }
    public void setResponseHeaders(Map<String, String> value) { headers = value; }
    public InputStream getData() { return data; }
    public void setData(InputStream value) { data = value; }
}
