package android.provider;

import android.content.ContentResolver;

/** Settings values that a stock device would report; everything else is absent. */
public class Settings {
    private static String value(String name) { return "android_id".equals(name) ? "9774d56d682e549c" : null; }
    public static class Secure {
        public static final String ANDROID_ID = "android_id";
        public static String getString(ContentResolver resolver, String name) { return value(name); }
        public static int getInt(ContentResolver resolver, String name, int fallback) { return fallback; }
    }
    public static class Global {
        public static String getString(ContentResolver resolver, String name) { return value(name); }
        public static int getInt(ContentResolver resolver, String name, int fallback) { return fallback; }
    }
    public static class System {
        public static String getString(ContentResolver resolver, String name) { return value(name); }
        public static int getInt(ContentResolver resolver, String name, int fallback) { return fallback; }
    }
}
