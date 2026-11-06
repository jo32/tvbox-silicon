package android.net.ssl;

import javax.net.ssl.SSLSocket;

/** Android 10's socket helpers; this host's sockets are the JDK's, which these do not apply to. */
public final class SSLSockets {
    private SSLSockets() { }
    public static boolean isSupportedSocket(SSLSocket socket) { return false; }
    public static void setUseSessionTickets(SSLSocket socket, boolean useSessionTickets) { throw new IllegalArgumentException("not a conscrypt socket"); }
    public static byte[] exportKeyingMaterial(SSLSocket socket, String label, byte[] context, int length) { throw new IllegalArgumentException("not a conscrypt socket"); }
}
