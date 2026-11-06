package android.telephony;

/** getSystemService("phone"): a device without a SIM, whose identifiers apps may not read (Android 10+). */
public class TelephonyManager {
    public static final int PHONE_TYPE_NONE = 0, SIM_STATE_ABSENT = 1, NETWORK_TYPE_UNKNOWN = 0;
    public TelephonyManager() { }
    public String getDeviceId() { return null; }
    public String getDeviceId(int slot) { return null; }
    public String getImei() { return null; }
    public String getMeid() { return null; }
    public String getSubscriberId() { return null; }
    public String getSimSerialNumber() { return null; }
    public String getLine1Number() { return null; }
    public String getSimOperator() { return ""; }
    public String getSimOperatorName() { return ""; }
    public String getSimCountryIso() { return ""; }
    public String getNetworkOperator() { return ""; }
    public String getNetworkOperatorName() { return ""; }
    public String getNetworkCountryIso() { return ""; }
    public int getPhoneType() { return PHONE_TYPE_NONE; }
    public int getSimState() { return SIM_STATE_ABSENT; }
    public int getNetworkType() { return NETWORK_TYPE_UNKNOWN; }
    public int getDataNetworkType() { return NETWORK_TYPE_UNKNOWN; }
    public boolean isNetworkRoaming() { return false; }
    public boolean hasIccCard() { return false; }
}
