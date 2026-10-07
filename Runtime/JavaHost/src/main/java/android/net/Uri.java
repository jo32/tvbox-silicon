package android.net;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * Android's Uri contract on the JVM. Plugins use it to build and take apart page and API
 * addresses; like Android, parsing is lenient and never throws, and parts are kept encoded.
 */
public class Uri implements Comparable<Uri> {
    public static final Uri EMPTY = new Uri(null, null, null, null, null, "");
    private static final String UNRESERVED = "_-!.~'()*";

    private final String scheme, authority, path, query, fragment, text;

    private Uri(String scheme, String authority, String path, String query, String fragment, String text) {
        this.scheme = scheme; this.authority = authority; this.path = path; this.query = query; this.fragment = fragment;
        this.text = text != null ? text : compose(scheme, authority, path, query, fragment);
    }

    private static String compose(String scheme, String authority, String path, String query, String fragment) {
        StringBuilder out = new StringBuilder();
        if (scheme != null) out.append(scheme).append(':');
        if (authority != null) out.append("//").append(authority);
        if (path != null) {
            if (authority != null && !path.isEmpty() && !path.startsWith("/")) out.append('/');
            out.append(path);
        }
        if (query != null) out.append('?').append(query);
        if (fragment != null) out.append('#').append(fragment);
        return out.toString();
    }

    public static Uri parse(String text) {
        if (text == null) throw new NullPointerException("uriString");
        String rest = text, scheme = null, authority = null, query = null, fragment = null;
        int hash = rest.indexOf('#');
        if (hash >= 0) { fragment = rest.substring(hash + 1); rest = rest.substring(0, hash); }
        int colon = rest.indexOf(':');
        int slash = rest.indexOf('/'), question = rest.indexOf('?');
        if (colon > 0 && (slash < 0 || colon < slash) && (question < 0 || colon < question)) {
            scheme = rest.substring(0, colon); rest = rest.substring(colon + 1);
        }
        boolean hierarchical = scheme == null || rest.startsWith("/");
        if (!hierarchical) {
            // Opaque (mailto:, magnet:?xt=...): Android exposes everything after ':' as the scheme-specific part.
            return new Uri(scheme, null, null, null, fragment, text) { };
        }
        int mark = rest.indexOf('?');
        if (mark >= 0) { query = rest.substring(mark + 1); rest = rest.substring(0, mark); }
        if (rest.startsWith("//")) {
            int end = rest.indexOf('/', 2);
            authority = end < 0 ? rest.substring(2) : rest.substring(2, end);
            rest = end < 0 ? "" : rest.substring(end);
        }
        return new Uri(scheme, authority, rest, query, fragment, text);
    }

    public static Uri fromFile(File file) { return new Builder().scheme("file").authority("").path(file.getAbsolutePath()).build(); }
    public static Uri fromParts(String scheme, String ssp, String fragment) {
        return parse(scheme + ":" + encode(ssp, "/:@?=&") + (fragment == null ? "" : "#" + encode(fragment)));
    }
    public static Uri withAppendedPath(Uri base, String segment) { return base.buildUpon().appendEncodedPath(segment).build(); }

    public String getScheme() { return scheme; }
    public boolean isHierarchical() { return scheme == null || text.startsWith(scheme + ":/"); }
    public boolean isOpaque() { return !isHierarchical(); }
    public boolean isAbsolute() { return scheme != null; }
    public boolean isRelative() { return scheme == null; }
    public String getEncodedSchemeSpecificPart() {
        String body = scheme == null ? text : text.substring(scheme.length() + 1);
        int hash = body.indexOf('#');
        return hash < 0 ? body : body.substring(0, hash);
    }
    public String getSchemeSpecificPart() { return decode(getEncodedSchemeSpecificPart()); }
    public String getEncodedAuthority() { return authority; }
    public String getAuthority() { return decode(authority); }
    public String getEncodedUserInfo() { int at = authority == null ? -1 : authority.lastIndexOf('@'); return at < 0 ? null : authority.substring(0, at); }
    public String getUserInfo() { return decode(getEncodedUserInfo()); }
    private String hostAndPort() { if (authority == null) return null; int at = authority.lastIndexOf('@'); return at < 0 ? authority : authority.substring(at + 1); }
    public String getHost() {
        String host = hostAndPort();
        if (host == null) return null;
        if (host.startsWith("[")) { int end = host.indexOf(']'); return end < 0 ? host : host.substring(0, end + 1); }
        int colon = host.lastIndexOf(':');
        return decode(colon < 0 ? host : host.substring(0, colon));
    }
    public int getPort() {
        String host = hostAndPort();
        if (host == null) return -1;
        int colon = host.lastIndexOf(':');
        if (colon < 0 || host.indexOf(']', colon) >= 0) return -1;
        try { return Integer.parseInt(host.substring(colon + 1)); } catch (NumberFormatException invalid) { return -1; }
    }
    public String getEncodedPath() { return path; }
    public String getPath() { return decode(path); }
    public String getEncodedQuery() { return query; }
    public String getQuery() { return decode(query); }
    public String getEncodedFragment() { return fragment; }
    public String getFragment() { return decode(fragment); }
    public List<String> getPathSegments() {
        if (path == null) return Collections.emptyList();
        List<String> segments = new ArrayList<>();
        for (String part : path.split("/")) if (!part.isEmpty()) segments.add(decode(part));
        return Collections.unmodifiableList(segments);
    }
    public String getLastPathSegment() { List<String> segments = getPathSegments(); return segments.isEmpty() ? null : segments.get(segments.size() - 1); }

    private List<String[]> pairs() {
        List<String[]> pairs = new ArrayList<>();
        if (query == null || query.isEmpty()) return pairs;
        for (String part : query.split("&", -1)) {
            int equals = part.indexOf('=');
            pairs.add(equals < 0 ? new String[]{part, ""} : new String[]{part.substring(0, equals), part.substring(equals + 1)});
        }
        return pairs;
    }
    public String getQueryParameter(String key) {
        if (isOpaque()) throw new UnsupportedOperationException("This isn't a hierarchical URI.");
        String encoded = encode(key, null);
        for (String[] pair : pairs()) if (pair[0].equals(encoded) || decode(pair[0]).equals(key)) return decodePlus(pair[1]);
        return null;
    }
    public List<String> getQueryParameters(String key) {
        List<String> values = new ArrayList<>();
        for (String[] pair : pairs()) if (decode(pair[0]).equals(key)) values.add(decodePlus(pair[1]));
        return Collections.unmodifiableList(values);
    }
    public Set<String> getQueryParameterNames() {
        Set<String> names = new LinkedHashSet<>();
        for (String[] pair : pairs()) names.add(decode(pair[0]));
        return Collections.unmodifiableSet(names);
    }
    public boolean getBooleanQueryParameter(String key, boolean fallback) {
        String value = getQueryParameter(key);
        if (value == null) return fallback;
        value = value.toLowerCase(Locale.ROOT);
        return !"false".equals(value) && !"0".equals(value);
    }
    public Uri normalizeScheme() { return scheme == null || scheme.equals(scheme.toLowerCase(Locale.ROOT)) ? this : buildUpon().scheme(scheme.toLowerCase(Locale.ROOT)).build(); }
    public Builder buildUpon() {
        return new Builder().scheme(scheme).encodedAuthority(authority).encodedPath(path).encodedQuery(query).encodedFragment(fragment);
    }

    @Override public String toString() { return text; }
    @Override public boolean equals(Object other) { return other instanceof Uri uri && text.equals(uri.text); }
    @Override public int hashCode() { return text.hashCode(); }
    @Override public int compareTo(Uri other) { return text.compareTo(other.text); }

    public static String encode(String text) { return encode(text, null); }
    public static String encode(String text, String allow) {
        if (text == null) return null;
        StringBuilder out = new StringBuilder();
        for (byte value : text.getBytes(StandardCharsets.UTF_8)) {
            int b = value & 0xff;
            char c = (char) b;
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || UNRESERVED.indexOf(c) >= 0 || (allow != null && b < 128 && allow.indexOf(c) >= 0)) out.append(c);
            else out.append('%').append("0123456789ABCDEF".charAt(b >> 4)).append("0123456789ABCDEF".charAt(b & 15));
        }
        return out.toString();
    }
    public static String decode(String text) { return decode(text, false); }
    private static String decodePlus(String text) { return decode(text, true); }
    private static String decode(String text, boolean plus) {
        if (text == null) return null;
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '%' && i + 2 < text.length() && Character.digit(text.charAt(i + 1), 16) >= 0 && Character.digit(text.charAt(i + 2), 16) >= 0) {
                bytes.write(Character.digit(text.charAt(i + 1), 16) * 16 + Character.digit(text.charAt(i + 2), 16)); i += 2;
            } else if (plus && c == '+') bytes.write(' ');
            else { byte[] raw = String.valueOf(c).getBytes(StandardCharsets.UTF_8); bytes.write(raw, 0, raw.length); }
        }
        return bytes.toString(StandardCharsets.UTF_8);
    }

    public static final class Builder {
        private String scheme, authority, path, query, fragment;
        public Builder scheme(String value) { scheme = value; return this; }
        public Builder opaquePart(String value) { path = value; authority = null; return this; }
        public Builder encodedOpaquePart(String value) { return opaquePart(value); }
        public Builder authority(String value) { authority = value == null ? null : encode(value, "@:[]"); return this; }
        public Builder encodedAuthority(String value) { authority = value; return this; }
        public Builder path(String value) { path = value == null ? null : encode(value, "/"); return this; }
        public Builder encodedPath(String value) { path = value; return this; }
        public Builder appendPath(String segment) { return appendEncodedPath(encode(segment)); }
        public Builder appendEncodedPath(String segment) {
            if (path == null || path.isEmpty()) path = segment.startsWith("/") ? segment : "/" + segment;
            else path = (path.endsWith("/") ? path : path + "/") + (segment.startsWith("/") ? segment.substring(1) : segment);
            return this;
        }
        public Builder query(String value) { query = value == null ? null : encode(value, "=&"); return this; }
        public Builder encodedQuery(String value) { query = value; return this; }
        public Builder appendQueryParameter(String key, String value) {
            String pair = encode(key, null) + "=" + encode(value, null);
            query = query == null || query.isEmpty() ? pair : query + "&" + pair;
            return this;
        }
        public Builder clearQuery() { query = null; return this; }
        public Builder fragment(String value) { fragment = value == null ? null : encode(value, null); return this; }
        public Builder encodedFragment(String value) { fragment = value; return this; }
        public Uri build() { return new Uri(scheme, authority, path == null && authority != null ? "" : path, query, fragment, null); }
        @Override public String toString() { return build().toString(); }
    }
}
