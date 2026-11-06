package android.net.wifi;

/** getSystemService("wifi"): Wi-Fi is on and connected. */
public class WifiManager {
    public static final int WIFI_STATE_ENABLED = 3;
    public WifiManager() { }
    public WifiInfo getConnectionInfo() { return new WifiInfo(); }
    public boolean isWifiEnabled() { return true; }
    public int getWifiState() { return WIFI_STATE_ENABLED; }
    public boolean setWifiEnabled(boolean enabled) { return false; }
    public static int calculateSignalLevel(int rssi, int numLevels) { return Math.max(0, Math.min(numLevels - 1, (rssi + 100) * (numLevels - 1) / 45)); }
    public class WifiLock { public void acquire() { } public void release() { } public boolean isHeld() { return false; } public void setReferenceCounted(boolean value) { } }
    public class MulticastLock { public void acquire() { } public void release() { } public boolean isHeld() { return false; } public void setReferenceCounted(boolean value) { } }
    public WifiLock createWifiLock(int mode, String tag) { return new WifiLock(); }
    public WifiLock createWifiLock(String tag) { return new WifiLock(); }
    public MulticastLock createMulticastLock(String tag) { return new MulticastLock(); }
}
