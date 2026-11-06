package android.content;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The clipboard. What a plugin copies (a link, a code to paste somewhere else) also goes to the app
 * (tvbox.runtime.PluginWindows), which puts it on the device's pasteboard.
 */
public class ClipboardManager extends android.text.ClipboardManager {
    public interface OnPrimaryClipChangedListener { void onPrimaryClipChanged(); }
    private static volatile ClipData clip;
    private static final List<OnPrimaryClipChangedListener> listeners = new CopyOnWriteArrayList<>();

    public ClipboardManager() { }
    public void setPrimaryClip(ClipData value) {
        if (value == null) throw new NullPointerException("clip");
        clip = value;
        CharSequence text = value.getItemCount() == 0 ? null : value.getItemAt(0).coerceToText(null);
        if (text != null) tvbox.runtime.PluginWindows.copied(text.toString());
        for (var listener : listeners) listener.onPrimaryClipChanged();
    }
    public void clearPrimaryClip() { clip = null; }
    public ClipData getPrimaryClip() { return clip; }
    public ClipDescription getPrimaryClipDescription() { return null; }
    public boolean hasPrimaryClip() { return clip != null; }
    public void addPrimaryClipChangedListener(OnPrimaryClipChangedListener listener) { listeners.add(listener); }
    public void removePrimaryClipChangedListener(OnPrimaryClipChangedListener listener) { listeners.remove(listener); }
    @Override public CharSequence getText() { ClipData now = clip; return now == null || now.getItemCount() == 0 ? null : now.getItemAt(0).getText(); }
    @Override public void setText(CharSequence text) { setPrimaryClip(ClipData.newPlainText(null, text)); }
    @Override public boolean hasText() { return getText() != null; }
}
