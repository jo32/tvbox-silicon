package android.content.pm;

import java.util.Arrays;

/** An APK signing certificate. Plugins hash it to identify the host app. */
public class Signature {
    private final byte[] signature;
    public Signature(byte[] signature) { this.signature = signature.clone(); }
    public Signature(String text) {
        signature = new byte[text.length() / 2];
        for (int i = 0; i < signature.length; i++) signature[i] = (byte) Integer.parseInt(text.substring(i * 2, i * 2 + 2), 16);
    }
    public byte[] toByteArray() { return signature.clone(); }
    public char[] toChars() { return toCharsString().toCharArray(); }
    public String toCharsString() {
        StringBuilder text = new StringBuilder(signature.length * 2);
        for (byte b : signature) text.append(Character.forDigit((b >> 4) & 15, 16)).append(Character.forDigit(b & 15, 16));
        return text.toString();
    }
    @Override public boolean equals(Object other) { return other instanceof Signature s && Arrays.equals(signature, s.signature); }
    @Override public int hashCode() { return Arrays.hashCode(signature); }
}
