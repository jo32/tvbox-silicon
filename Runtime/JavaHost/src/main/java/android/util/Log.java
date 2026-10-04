package android.util;
public final class Log {
    public static int d(String tag, String text) { System.err.println("["+tag+"] "+text); return 0; }
    public static int i(String tag, String text) { return d(tag,text); }
    public static int e(String tag, String text) { return d(tag,text); }
    public static int w(String tag, String text) { return d(tag,text); }
    public static int v(String tag, String text) { return d(tag,text); }
    public static int e(String tag, String text, Throwable e) { d(tag,text); e.printStackTrace(System.err); return 0; }
    public static String getStackTraceString(Throwable error) { java.io.StringWriter w = new java.io.StringWriter(); error.printStackTrace(new java.io.PrintWriter(w)); return w.toString(); }
}
