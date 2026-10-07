package com.tencent.smtt.sdk;

import android.content.Context;

/**
 * Tencent X5 entry point. Apple platforms have no X5 core, so every call reports what Android
 * reports on a device without one: initialization finishes and the X5 view is unavailable.
 */
public class QbSdk {
    public interface PreInitCallback {
        void onCoreInitFinished();
        void onViewInitFinished(boolean isX5);
    }

    public static void initX5Environment(Context context, PreInitCallback callback) {
        if (callback == null) return;
        callback.onCoreInitFinished();
        callback.onViewInitFinished(false);
    }
    public static void preInit(Context context, PreInitCallback callback) { initX5Environment(context, callback); }
    public static void preInit(Context context) { }
    public static boolean isTbsCoreInited() { return false; }
    public static boolean canLoadX5(Context context) { return false; }
    public static int getTbsVersion(Context context) { return 0; }
    public static void setTbsListener(TbsListener listener) { }
    public static void setDownloadWithoutWifi(boolean enabled) { }
    public static void setCoreMinVersion(int version) { }
    public static void initTbsSettings(java.util.Map<String, Object> settings) { }
    public static void forceSysWebView() { }
}
