package android.widget;

/** Noninteractive plugin notices are delivered to the host diagnostic stream. */
public class Toast {
    public static final int LENGTH_SHORT = 0, LENGTH_LONG = 1;
    private CharSequence text = "";
    private int duration;
    public Toast(android.content.Context context) { }
    public static Toast makeText(android.content.Context context, CharSequence text, int duration) {
        Toast toast = new Toast(context); toast.text = text; toast.duration = duration; return toast;
    }
    public void show() { System.err.println("PLUGIN_NOTICE " + text); }
    public void cancel() { }
    public void setText(CharSequence value) { text = value; }
    public void setDuration(int value) { duration = value; }
    public int getDuration() { return duration; }
    public void setGravity(int gravity, int xOffset, int yOffset) { }
}
