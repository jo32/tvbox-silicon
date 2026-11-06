package android.text;

/** The old text-only clipboard API, which android.content.ClipboardManager extends. */
public abstract class ClipboardManager {
    public abstract CharSequence getText();
    public abstract void setText(CharSequence text);
    public abstract boolean hasText();
}
