package android.util;
public final class Base64 {
    public static final int DEFAULT=0, NO_PADDING=1, NO_WRAP=2, CRLF=4, URL_SAFE=8, NO_CLOSE=16;
    public static byte[] decode(String input, int flags) { return decoder(flags).decode(input.replaceAll("\\s", "")); }
    public static byte[] decode(byte[] input, int flags) { return decode(new String(input, java.nio.charset.StandardCharsets.US_ASCII),flags); }
    public static byte[] decode(byte[] input, int offset, int length, int flags) { return decode(java.util.Arrays.copyOfRange(input,offset,offset+length),flags); }
    public static String encodeToString(byte[] input, int flags) {
        var encoder=(flags&URL_SAFE)!=0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if((flags&NO_PADDING)!=0) encoder=encoder.withoutPadding();
        String value=encoder.encodeToString(input);
        if ((flags&NO_WRAP)!=0 || value.isEmpty()) return value;
        String newline=(flags&CRLF)!=0 ? "\r\n" : "\n";
        StringBuilder result=new StringBuilder();
        for(int i=0;i<value.length();i+=76) result.append(value,i,Math.min(i+76,value.length())).append(newline);
        return result.toString();
    }
    public static String encodeToString(byte[] input, int offset, int length, int flags) { return encodeToString(java.util.Arrays.copyOfRange(input,offset,offset+length),flags); }
    public static byte[] encode(byte[] input,int flags) { return encodeToString(input,flags).getBytes(java.nio.charset.StandardCharsets.US_ASCII); }
    private static java.util.Base64.Decoder decoder(int flags) { return (flags&URL_SAFE)!=0 ? java.util.Base64.getUrlDecoder() : java.util.Base64.getDecoder(); }
}
