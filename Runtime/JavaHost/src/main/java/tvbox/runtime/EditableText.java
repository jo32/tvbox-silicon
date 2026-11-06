package tvbox.runtime;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

/** An EditText's text: android.text.Editable over a StringBuilder, like SpannableStringBuilder without spans. */
public final class EditableText implements InvocationHandler {
    private final StringBuilder text = new StringBuilder();
    private Object filters;

    public static android.text.Editable create(CharSequence initial) {
        EditableText handler = new EditableText();
        if (initial != null) handler.text.append(initial);
        return (android.text.Editable) Proxy.newProxyInstance(android.text.Editable.class.getClassLoader(),
            new Class<?>[]{android.text.Editable.class}, handler);
    }

    @Override public Object invoke(Object self, Method method, Object[] a) {
        String name = method.getName();
        int count = a == null ? 0 : a.length;
        switch (name) {
            case "toString": return text.toString();
            case "length": return text.length();
            case "isEmpty": return text.length() == 0;
            case "charAt": return text.charAt((Integer) a[0]);
            case "subSequence": return text.substring((Integer) a[0], (Integer) a[1]);
            case "chars": return text.chars();
            case "codePoints": return text.codePoints();
            case "equals": return self == a[0];
            case "hashCode": return System.identityHashCode(self);
            case "getChars": text.getChars((Integer) a[0], (Integer) a[1], (char[]) a[2], (Integer) a[3]); return null;
            case "clear": text.setLength(0); return null;
            case "clearSpans": case "setSpan": case "removeSpan": return null;
            case "append":
                if (a[0] instanceof Character c) text.append((char) c);
                else if (count == 3) text.append((CharSequence) a[0], (Integer) a[1], (Integer) a[2]);
                else text.append((CharSequence) a[0]);
                return self;
            case "insert":
                CharSequence inserted = (CharSequence) a[1];
                text.insert((Integer) a[0], count == 4 ? inserted.subSequence((Integer) a[2], (Integer) a[3]) : inserted);
                return self;
            case "replace":
                CharSequence replacement = (CharSequence) a[2];
                text.replace((Integer) a[0], (Integer) a[1], String.valueOf(count == 5 ? replacement.subSequence((Integer) a[3], (Integer) a[4]) : replacement));
                return self;
            case "delete": text.delete((Integer) a[0], (Integer) a[1]); return self;
            case "getSpans": return java.lang.reflect.Array.newInstance((Class<?>) a[2], 0);
            case "getSpanStart": case "getSpanEnd": return -1;
            case "getSpanFlags": return 0;
            case "nextSpanTransition": return a[1];
            case "setFilters": filters = a[0]; return null;
            case "getFilters": return filters != null ? filters : java.lang.reflect.Array.newInstance(method.getReturnType().getComponentType(), 0);
            default: break;
        }
        Class<?> type = method.getReturnType();
        if (type == boolean.class) return false;
        if (type == int.class) return 0;
        if (type == char.class) return '\0';
        if (type.isInstance(self)) return self;
        return null;
    }
}
