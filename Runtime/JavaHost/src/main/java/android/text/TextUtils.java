package android.text;
import java.util.*;
public final class TextUtils {
    public static boolean isEmpty(CharSequence text) { return text == null || text.length() == 0; }
    public static boolean equals(CharSequence a, CharSequence b) { return a==b || a!=null && b!=null && a.toString().contentEquals(b); }
    public static String join(CharSequence delimiter, Iterable<?> tokens) { StringJoiner join = new StringJoiner(delimiter); tokens.forEach(v -> join.add(String.valueOf(v))); return join.toString(); }
    public static String join(CharSequence delimiter, Object[] tokens) { return join(delimiter, Arrays.asList(tokens)); }
    public static String[] split(String text, String expression) { return text.isEmpty() ? new String[0] : text.split(expression,-1); }
}
