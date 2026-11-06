package android.widget;

import android.content.Context;

public class Switch extends CompoundButton {
    public Switch(Context context) { super(context); }
    public Switch(Context context, android.util.AttributeSet attrs) { super(context); }
    public Switch(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public void setShowText(boolean value) { }
    public void setTextOn(CharSequence value) { }
    public void setTextOff(CharSequence value) { }
    public void setThumbDrawable(android.graphics.drawable.Drawable value) { }
    public void setTrackDrawable(android.graphics.drawable.Drawable value) { }
    public void setThumbTintList(android.content.res.ColorStateList value) { }
    public void setTrackTintList(android.content.res.ColorStateList value) { }
    public void setSwitchMinWidth(int value) { }
    public void setSwitchPadding(int value) { }
    @Override protected String tvboxKind() { return "switch"; }
}
