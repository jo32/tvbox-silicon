package com.github.catvod.spider;
import android.app.Application;
public final class Init {
    public static Application application;
    public static Application context() { return application; }
    public static ClassLoader classLoader() { return application.getClassLoader(); }
}
