package android.net.wifi;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Collections;

/** The device's Wi-Fi connection; the address is its LAN IPv4 address, little-endian as Android gives it. */
public class WifiInfo {
    public WifiInfo() { }
    public int getIpAddress() {
        byte[] bytes = lanAddress();
        if (bytes == null) return 0;
        return (bytes[3] & 255) << 24 | (bytes[2] & 255) << 16 | (bytes[1] & 255) << 8 | (bytes[0] & 255);
    }
    /** The first private IPv4 address of an interface that is up (Wi-Fi or Ethernet), else loopback. */
    public static byte[] lanAddress() {
        try {
            byte[] fallback = null;
            for (NetworkInterface face : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!face.isUp() || face.isLoopback() || face.isVirtual() || face.isPointToPoint()) continue;
                for (InetAddress address : Collections.list(face.getInetAddresses())) {
                    if (!(address instanceof Inet4Address) || address.isLinkLocalAddress()) continue;
                    if (address.isSiteLocalAddress()) return address.getAddress();
                    if (fallback == null) fallback = address.getAddress();
                }
            }
            return fallback != null ? fallback : new byte[]{127, 0, 0, 1};
        } catch (Exception failed) { return new byte[]{127, 0, 0, 1}; }
    }
    public String getSSID() { return "<unknown ssid>"; }
    public String getBSSID() { return "02:00:00:00:00:00"; }
    public String getMacAddress() { return "02:00:00:00:00:00"; }
    public int getRssi() { return -50; }
    public int getLinkSpeed() { return 433; }
    public int getFrequency() { return 5180; }
    public int getNetworkId() { return 0; }
    public boolean getHiddenSSID() { return false; }
}
