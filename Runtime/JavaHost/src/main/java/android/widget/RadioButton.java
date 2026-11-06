package android.widget;

import android.content.Context;

public class RadioButton extends CompoundButton {
    public RadioButton(Context context) { super(context); }
    public RadioButton(Context context, android.util.AttributeSet attrs) { super(context); }
    public RadioButton(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    /** A tap only turns a radio button on; its group turns the others off. */
    @Override public void toggle() { if (!isChecked()) super.toggle(); }
    @Override protected String tvboxKind() { return "radio"; }
}
