package android.util;
public final class Base64 {
    public static final int DEFAULT=0, NO_PADDING=1, NO_WRAP=2, CRLF=4, URL_SAFE=8, NO_CLOSE=16;
    public static byte[] decode(String input, int flags) { return decode(input.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1), flags); }
    public static byte[] decode(byte[] input, int flags) { return decode(input, 0, input.length, flags); }
    /**
     * Android's decoder, not java.util's: it skips every byte outside the alphabet (whitespace, but
     * also '.', '_' or '-' in DEFAULT mode), and padding is optional. Plugins rely on that, e.g. the
     * aowu 七味/SeedHub spiders decode strings containing '.' and '_'. Like Android, a lone trailing
     * digit, a single '=' or a digit after the padding is "bad base-64".
     */
    public static byte[] decode(byte[] input, int offset, int length, int flags) {
        boolean web = (flags & URL_SAFE) != 0;
        var output = new java.io.ByteArrayOutputStream(length * 3 / 4 + 3);
        int state = 0, value = 0;
        for (int p = offset; p < offset + length; p++) {
            int d = digit(input[p] & 0xff, web);
            switch (state) {
                case 0: if (d >= 0) { value = d; state = 1; } else if (d != SKIP) throw bad(); break;
                case 1: if (d >= 0) { value = value << 6 | d; state = 2; } else if (d != SKIP) throw bad(); break;
                case 2:
                    if (d >= 0) { value = value << 6 | d; state = 3; }
                    else if (d == EQUALS) { output.write(value >> 4); state = 4; }
                    else if (d != SKIP) throw bad();
                    break;
                case 3:
                    if (d >= 0) { value = value << 6 | d; output.write(value >> 16); output.write(value >> 8); output.write(value); state = 0; }
                    else if (d == EQUALS) { output.write(value >> 10); output.write(value >> 2); state = 5; }
                    else if (d != SKIP) throw bad();
                    break;
                case 4: if (d == EQUALS) state = 5; else if (d != SKIP) throw bad(); break;
                default: if (d != SKIP) throw bad(); break;
            }
        }
        switch (state) {
            case 1: case 4: throw bad();
            case 2: output.write(value >> 4); break;
            case 3: output.write(value >> 10); output.write(value >> 2); break;
            default: break;
        }
        return output.toByteArray();
    }
    private static final int SKIP = -1, EQUALS = -2;
    private static int digit(int c, boolean web) {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '=') return EQUALS;
        if (c == (web ? '-' : '+')) return 62;
        if (c == (web ? '_' : '/')) return 63;
        return SKIP;
    }
    private static IllegalArgumentException bad() { return new IllegalArgumentException("bad base-64"); }
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
}
