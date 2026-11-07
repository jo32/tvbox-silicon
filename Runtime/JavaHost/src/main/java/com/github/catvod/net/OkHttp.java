package com.github.catvod.net;

import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import okhttp3.Dns;
import okhttp3.OkHttpClient;

/**
 * The HTTP client FongMi's new spider SDK (Net, Download) runs on: the host's spider client (its
 * diagnostics and dispatcher), with FongMi's 30-second timeouts and lenient TLS, which the spiders expect.
 */
public final class OkHttp {
    private static final long TIMEOUT = TimeUnit.SECONDS.toMillis(30);
    private static OkHttpClient client;

    private OkHttp() { }

    public static Dns dns() { return Dns.SYSTEM; }

    public static synchronized OkHttpClient client() {
        if (client != null) return client;
        X509TrustManager trust = trustAll();
        OkHttpClient.Builder builder = com.github.catvod.crawler.Spider.client().newBuilder()
            .connectTimeout(TIMEOUT, TimeUnit.MILLISECONDS).readTimeout(TIMEOUT, TimeUnit.MILLISECONDS)
            .writeTimeout(TIMEOUT, TimeUnit.MILLISECONDS).callTimeout(0, TimeUnit.MILLISECONDS)
            .hostnameVerifier((hostname, session) -> true);
        try {
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, new TrustManager[]{trust}, new SecureRandom());
            builder.sslSocketFactory(context.getSocketFactory(), trust);
        } catch (Exception unavailable) { unavailable.printStackTrace(System.err); }
        return client = builder.build();
    }

    private static X509TrustManager trustAll() {
        return new X509TrustManager() {
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType) { }
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType) { }
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        };
    }
}
