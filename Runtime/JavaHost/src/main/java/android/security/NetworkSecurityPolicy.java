package android.security;

/** Plain http is allowed, as for apps that target Android 8 and earlier (TVBox). */
public class NetworkSecurityPolicy {
    private static final NetworkSecurityPolicy INSTANCE = new NetworkSecurityPolicy();
    private NetworkSecurityPolicy() { }
    public static NetworkSecurityPolicy getInstance() { return INSTANCE; }
    public boolean isCleartextTrafficPermitted() { return true; }
    public boolean isCleartextTrafficPermitted(String hostname) { return true; }
}
