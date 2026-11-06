package android.content;

import java.util.ArrayList;
import java.util.List;

public class ClipData {
    public static class Item {
        private final CharSequence text;
        private final String html;
        private final Intent intent;
        private final android.net.Uri uri;
        public Item(CharSequence text) { this(text, null, null, null); }
        public Item(CharSequence text, String html) { this(text, html, null, null); }
        public Item(Intent intent) { this(null, null, intent, null); }
        public Item(android.net.Uri uri) { this(null, null, null, uri); }
        public Item(CharSequence text, Intent intent, android.net.Uri uri) { this(text, null, intent, uri); }
        public Item(CharSequence text, String html, Intent intent, android.net.Uri uri) { this.text = text; this.html = html; this.intent = intent; this.uri = uri; }
        public CharSequence getText() { return text; }
        public String getHtmlText() { return html; }
        public Intent getIntent() { return intent; }
        public android.net.Uri getUri() { return uri; }
        public CharSequence coerceToText(Context context) { return text != null ? text : uri != null ? uri.toString() : ""; }
    }

    private final CharSequence label;
    private final List<Item> items = new ArrayList<>();
    public ClipData(CharSequence label, String[] mimeTypes, Item item) { this.label = label; if (item != null) items.add(item); }
    public ClipData(ClipData other) { label = other.label; items.addAll(other.items); }
    public static ClipData newPlainText(CharSequence label, CharSequence text) { return new ClipData(label, new String[]{"text/plain"}, new Item(text)); }
    public static ClipData newHtmlText(CharSequence label, CharSequence text, String html) { return new ClipData(label, new String[]{"text/html"}, new Item(text, html)); }
    public static ClipData newRawUri(CharSequence label, android.net.Uri uri) { return new ClipData(label, new String[]{"text/uri-list"}, new Item(uri)); }
    public void addItem(Item item) { if (item != null) items.add(item); }
    public int getItemCount() { return items.size(); }
    public Item getItemAt(int index) { return items.get(index); }
    public CharSequence tvboxLabel() { return label; }
}
