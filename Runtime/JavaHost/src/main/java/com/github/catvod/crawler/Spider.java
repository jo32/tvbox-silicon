package com.github.catvod.crawler;
import android.content.Context;
import okhttp3.Dns;
import okhttp3.OkHttpClient;
import java.util.*;
import java.util.concurrent.TimeUnit;
/** CatVod host contract; each plugin supplies its own content implementation. */
public abstract class Spider {
    public String siteKey;
    private static final OkHttpClient HTTP = new OkHttpClient.Builder()
        .addInterceptor(chain -> {
            var request = chain.request();
            System.err.println("HTTP " + request.url().scheme() + "://" + request.url().host() + request.url().encodedPath());
            try {
                var response = chain.proceed(request);
                System.err.println("HTTP_RESULT " + response.code());
                if (!response.isSuccessful() && !request.url().host().equals("127.0.0.1") && !request.url().host().equals("localhost")) {
                    tvbox.runtime.HttpDiagnostics.recordStatus(request.url().host(), response.code());
                }
                return response;
            } catch (Exception error) { error.printStackTrace(System.err); throw error; }
        }).connectTimeout(20, TimeUnit.SECONDS).readTimeout(25, TimeUnit.SECONDS).callTimeout(35, TimeUnit.SECONDS).build();
    public static Dns safeDns() { return Dns.SYSTEM; }
    public static OkHttpClient client() { return HTTP; }
    public void init(Context context) throws Exception { }
    public void init(Context context, String extension) throws Exception { init(context); }
    public String homeContent(boolean filter) throws Exception { return ""; }
    public String homeVideoContent() throws Exception { return ""; }
    public String categoryContent(String type, String page, boolean filter, HashMap<String,String> ext) throws Exception { return ""; }
    public String detailContent(List<String> ids) throws Exception { return ""; }
    public String searchContent(String query, boolean quick) throws Exception { return ""; }
    public String searchContent(String query, boolean quick, String page) throws Exception { return searchContent(query, quick); }
    public String playerContent(String flag, String id, List<String> flags) throws Exception { return ""; }
    public String liveContent(String url) throws Exception { return ""; }
    public String action(String action) throws Exception { return ""; }
    public Object[] proxy(Map<String,String> request) throws Exception { return null; }
    public boolean manualVideoCheck() { return false; }
    public boolean isVideoFormat(String url) { return false; }
    public void destroy() { }
}
