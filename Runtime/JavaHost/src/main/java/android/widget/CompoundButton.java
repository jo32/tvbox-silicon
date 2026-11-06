package android.widget;

import android.content.Context;

public abstract class CompoundButton extends Button implements Checkable {
    public interface OnCheckedChangeListener { void onCheckedChanged(CompoundButton button, boolean checked); }
    private boolean checked, broadcasting;
    private OnCheckedChangeListener listener;

    public CompoundButton(Context context) { super(context); setGravity(0x800013); }
    public CompoundButton(Context context, android.util.AttributeSet attrs) { this(context); }
    public CompoundButton(Context context, android.util.AttributeSet attrs, int defStyleAttr) { this(context); }

    @Override public boolean isChecked() { return checked; }
    @Override public void setChecked(boolean value) {
        if (checked == value) return;
        checked = value;
        if (broadcasting) return;
        broadcasting = true;
        try {
            if (listener != null) listener.onCheckedChanged(this, checked);
            if (checked && getParent() instanceof RadioGroup group && this instanceof RadioButton) group.tvboxChecked((RadioButton) this);
        } finally { broadcasting = false; }
    }
    @Override public void toggle() { setChecked(!checked); }
    @Override public boolean performClick() { toggle(); return super.performClick() || true; }
    public void setOnCheckedChangeListener(OnCheckedChangeListener value) { listener = value; }
    public void setButtonDrawable(android.graphics.drawable.Drawable drawable) { }
    public void setButtonDrawable(int resid) { }
    public void setButtonTintList(android.content.res.ColorStateList tint) { }
    @Override protected boolean tvboxChecked() { return checked; }
    @Override public boolean tvboxTappable() { return true; }
    @Override public void tvboxSetValue(Object value) { if (value instanceof Boolean on && on != checked) tvboxActivate(); }
    protected String tvboxKind() { return "check"; }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        super.tvboxDescribe(node);
        node.put("type", tvboxKind()).put("checked", checked);
    }
}
