package android.media;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.UUID;

/**
 * Widevine as plugins use it: only to read a stable device id ("deviceUniqueId"), which here is derived from
 * the host's Android id, so it stays the same for this install. No content is ever decrypted.
 */
public final class MediaDrm implements AutoCloseable {
    public static final String PROPERTY_DEVICE_UNIQUE_ID = "deviceUniqueId", PROPERTY_VENDOR = "vendor", PROPERTY_VERSION = "version",
        PROPERTY_DESCRIPTION = "description", PROPERTY_ALGORITHMS = "algorithms";
    private static final UUID WIDEVINE = new UUID(0xEDEF8BA979D64ACEL, 0xA3C827DCD51D21EDL);
    private final UUID scheme;

    public MediaDrm(UUID uuid) throws UnsupportedSchemeException {
        if (!isCryptoSchemeSupported(uuid)) throw new UnsupportedSchemeException("Failed to instantiate drm object.");
        scheme = uuid;
    }
    public static boolean isCryptoSchemeSupported(UUID uuid) { return WIDEVINE.equals(uuid); }
    public static boolean isCryptoSchemeSupported(UUID uuid, String mimeType) { return isCryptoSchemeSupported(uuid); }
    public byte[] getPropertyByteArray(String name) {
        if (!PROPERTY_DEVICE_UNIQUE_ID.equals(name)) return new byte[0];
        try {
            String id = android.provider.Settings.Secure.getString(null, android.provider.Settings.Secure.ANDROID_ID);
            return MessageDigest.getInstance("SHA-256").digest(("tvbox-drm:" + scheme + ":" + id).getBytes(StandardCharsets.UTF_8));
        } catch (Exception impossible) { return new byte[32]; }
    }
    public String getPropertyString(String name) {
        return switch (name) {
            case PROPERTY_VENDOR -> "Google";
            case PROPERTY_VERSION -> "16.0.0";
            case PROPERTY_DESCRIPTION -> "Widevine CDM";
            case PROPERTY_ALGORITHMS -> "AES/CBC/NoPadding,HmacSHA256";
            case "securityLevel" -> "L3";
            default -> "";
        };
    }
    public void setPropertyString(String name, String value) { }
    public void setPropertyByteArray(String name, byte[] value) { }
    public void release() { }
    @Override public void close() { }
}
