package android.widget;

import android.content.Context;
import android.view.View;

public class ProgressBar extends View {
    private int min, max = 100, progress, secondary;
    private boolean indeterminate;
    public ProgressBar(Context context) { super(context); }
    public ProgressBar(Context context, android.util.AttributeSet attrs) { this(context); }
    public ProgressBar(Context context, android.util.AttributeSet attrs, int defStyleAttr) { this(context); indeterminate = defStyleAttr != 16842872; }
    public synchronized int getMax() { return max; }
    public synchronized void setMax(int value) { max = Math.max(value, min); if (progress > max) progress = max; }
    public synchronized int getMin() { return min; }
    public synchronized void setMin(int value) { min = value; }
    public synchronized int getProgress() { return indeterminate ? 0 : progress; }
    public synchronized void setProgress(int value) { setProgress(value, false); }
    public void setProgress(int value, boolean animate) { tvboxProgress(value, false); }
    void tvboxProgress(int value, boolean fromUser) {
        int clamped = Math.max(min, Math.min(max, value));
        if (clamped == progress) return;
        progress = clamped;
        onProgressRefresh(fromUser);
    }
    void onProgressRefresh(boolean fromUser) { }
    public synchronized void incrementProgressBy(int diff) { setProgress(progress + diff); }
    public synchronized int getSecondaryProgress() { return secondary; }
    public synchronized void setSecondaryProgress(int value) { secondary = value; }
    public synchronized boolean isIndeterminate() { return indeterminate; }
    public synchronized void setIndeterminate(boolean value) { indeterminate = value; }
    public void setProgressDrawable(android.graphics.drawable.Drawable d) { }
    public void setIndeterminateDrawable(android.graphics.drawable.Drawable d) { }
    public void setProgressTintList(android.content.res.ColorStateList tint) { }
    public void setIndeterminateTintList(android.content.res.ColorStateList tint) { }
    public void setProgressBackgroundTintList(android.content.res.ColorStateList tint) { }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        node.put("type", "progress").put("min", min).put("max", max).put("progress", progress);
        if (indeterminate) node.put("indeterminate", true);
    }
}
