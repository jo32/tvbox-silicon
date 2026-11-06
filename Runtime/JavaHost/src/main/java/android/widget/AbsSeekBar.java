package android.widget;

import android.content.Context;

public abstract class AbsSeekBar extends ProgressBar {
    private int keyIncrement = 1;
    public AbsSeekBar(Context context) { super(context); }
    public AbsSeekBar(Context context, android.util.AttributeSet attrs) { super(context); }
    public AbsSeekBar(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public void setThumb(android.graphics.drawable.Drawable thumb) { }
    public void setThumbOffset(int offset) { }
    public void setThumbTintList(android.content.res.ColorStateList tint) { }
    public void setKeyProgressIncrement(int value) { keyIncrement = Math.max(1, value); }
    public int getKeyProgressIncrement() { return keyIncrement; }
    public void setSplitTrack(boolean value) { }
}
