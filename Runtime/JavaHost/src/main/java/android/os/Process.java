package android.os;

/** Architecture describes the Android guest; process operations stay in this worker. */
public final class Process {
    public static boolean is64Bit() { return true; }
    public static int myPid() { return Math.toIntExact(ProcessHandle.current().pid()); }
    public static int myTid() { return (int) Thread.currentThread().getId(); }
    public static int myUid() { return 10000; }
    public static void killProcess(int pid) {
        if (pid != myPid()) throw new UnsupportedOperationException("A plugin cannot kill other host processes");
        throw new IllegalStateException("The plugin requested termination of its Android process");
    }
}
