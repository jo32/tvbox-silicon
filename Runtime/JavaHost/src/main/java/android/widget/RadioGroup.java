package android.widget;

import android.content.Context;
import android.view.View;

public class RadioGroup extends LinearLayout {
    public interface OnCheckedChangeListener { void onCheckedChanged(RadioGroup group, int checkedId); }
    private int checkedId = -1;
    private OnCheckedChangeListener listener;

    public RadioGroup(Context context) { super(context); setOrientation(VERTICAL); }
    public RadioGroup(Context context, android.util.AttributeSet attrs) { this(context); }

    public int getCheckedRadioButtonId() { return checkedId; }
    public void setOnCheckedChangeListener(OnCheckedChangeListener value) { listener = value; }
    public void check(int id) {
        if (id == -1) { clearCheck(); return; }
        if (id == checkedId) return;
        View found = findViewById(id);
        if (found instanceof RadioButton button && button.getParent() == this) button.setChecked(true);
        else changed(id);
    }
    public void clearCheck() {
        for (int i = 0; i < getChildCount(); i++) if (getChildAt(i) instanceof RadioButton button) button.setChecked(false);
        changed(-1);
    }
    @Override protected void onViewAdded(View child) {
        if (!(child instanceof RadioButton button)) return;
        if (button.getId() == NO_ID) button.setId(generateViewId());
        if (button.isChecked()) tvboxChecked(button);
    }
    void tvboxChecked(RadioButton button) {
        for (int i = 0; i < getChildCount(); i++) if (getChildAt(i) instanceof RadioButton other && other != button) other.setChecked(false);
        changed(button.getId());
    }
    private void changed(int id) {
        if (checkedId == id) return;
        checkedId = id;
        if (listener != null) listener.onCheckedChanged(this, id);
    }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        super.tvboxDescribe(node);
        node.put("type", "radios");
    }
}
