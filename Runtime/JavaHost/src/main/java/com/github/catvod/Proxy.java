package com.github.catvod;

/**
 * FongMi's new spider SDK: the app's local proxy. Spiders add {@code do=jar&siteKey=…} and the host hands
 * those requests to the source's {@code Spider.proxy} (see NativeProbe).
 */
public final class Proxy {
    private Proxy() { }

    public static String getUrl() { return getUrl(true); }

    /** {@code local=false} asks for an address other devices can reach; the bridge serves both alike. */
    public static String getUrl(boolean local) { return tvbox.runtime.CloudDriveBridge.getUrl(); }
}
