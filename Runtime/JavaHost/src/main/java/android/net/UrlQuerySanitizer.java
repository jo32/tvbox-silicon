package android.net;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Reads a URL's query parameters; values are unescaped (%XX and +), the first of each name kept. */
public class UrlQuerySanitizer {
    private final Map<String, String> values = new LinkedHashMap<>();
    private final List<String[]> list = new ArrayList<>();
    private boolean allowUnregistered = true;
    public UrlQuerySanitizer() { }
    public UrlQuerySanitizer(String url) { parseUrl(url); }
    public void parseUrl(String url) {
        int mark = url == null ? -1 : url.indexOf('?');
        parseQuery(mark < 0 ? "" : url.substring(mark + 1));
    }
    public void parseQuery(String query) {
        values.clear(); list.clear();
        int hash = query.indexOf('#');
        if (hash >= 0) query = query.substring(0, hash);
        for (String pair : query.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            String name = unescape(eq < 0 ? pair : pair.substring(0, eq)), value = eq < 0 ? "" : unescape(pair.substring(eq + 1));
            values.putIfAbsent(name, value);
            list.add(new String[]{name, value});
        }
    }
    public Set<String> getParameterSet() { return values.keySet(); }
    public boolean hasParameter(String name) { return values.containsKey(name); }
    public String getValue(String name) { return values.get(name); }
    public void setAllowUnregisteredParamaters(boolean value) { allowUnregistered = value; }
    public boolean getAllowUnregisteredParamaters() { return allowUnregistered; }
    public void setUnregisteredParameterValueSanitizer(Object sanitizer) { }
    public void registerParameter(String name, Object sanitizer) { }
    public void setPreferFirstRepeatedParameter(boolean value) { }
    public String unescape(String text) {
        try { return java.net.URLDecoder.decode(text, java.nio.charset.StandardCharsets.UTF_8); }
        catch (IllegalArgumentException broken) { return text.replace('+', ' '); }
    }
}
