package tvbox.runtime;
public final class AppleBootstrap {
    static {
        System.setProperty("tvbox.apple", "true");
        System.setProperty("jna.nosys", "false");
        System.setProperty("jna.noclasspath", "true");
        System.loadLibrary("unicorn");
        System.loadLibrary("disassembler");
        java.security.Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider());
    }
    public static String request(String input) {
        Thread worker = Thread.currentThread();
        Thread monitor = new Thread(() -> {
            try {
                while (true) {
                    Thread.sleep(60_000);
                    System.err.println("PLUGIN_BUSY stack:");
                    StackTraceElement[] frames = worker.getStackTrace();
                    for (int i = 0; i < Math.min(16, frames.length); i++) System.err.println("  " + frames[i]);
                }
            } catch (InterruptedException finished) { }
        }, "Plugin diagnostics");
        monitor.setDaemon(true);
        monitor.start();
        try { return InProcessHost.request(input); }
        finally { monitor.interrupt(); }
    }
}
