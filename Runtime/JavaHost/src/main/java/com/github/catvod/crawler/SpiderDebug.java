package com.github.catvod.crawler;
public final class SpiderDebug {
    public static void log(String text) { System.err.println("[Spider] " + text); }
    public static void log(Throwable error) { error.printStackTrace(System.err); }
}
