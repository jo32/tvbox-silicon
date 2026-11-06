package android.net;

/** getSystemService("connectivity"): the device is online over Wi-Fi. */
public class ConnectivityManager {
    public static final int TYPE_MOBILE = 0, TYPE_WIFI = 1, TYPE_ETHERNET = 9, TYPE_NONE = -1;
    public static final String CONNECTIVITY_ACTION = "android.net.conn.CONNECTIVITY_CHANGE";
    private static final NetworkInfo WIFI = new NetworkInfo(TYPE_WIFI);
    public ConnectivityManager() { }
    public NetworkInfo getActiveNetworkInfo() { return WIFI; }
    public NetworkInfo getNetworkInfo(int type) { return type == TYPE_WIFI ? WIFI : null; }
    public NetworkInfo[] getAllNetworkInfo() { return new NetworkInfo[]{WIFI}; }
    public boolean isActiveNetworkMetered() { return false; }
    public static boolean isNetworkTypeValid(int type) { return type >= 0 && type <= 17; }
    public int getRestrictBackgroundStatus() { return 1; }
}
