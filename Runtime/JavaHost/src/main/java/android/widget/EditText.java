package android.widget;

import android.content.Context;
import android.text.Editable;
import org.json.JSONException;
import org.json.JSONObject;

/** A field the viewer types into in the app; the text arrives before any tap is run. */
public class EditText extends TextView {
    private Editable editable = tvbox.runtime.EditableText.create("");

    public EditText(Context context) { super(context); setFocusable(true); setFocusableInTouchMode(true); }
    public EditText(Context context, android.util.AttributeSet attrs) { this(context); }
    public EditText(Context context, android.util.AttributeSet attrs, int defStyleAttr) { this(context); }

    @Override public Editable getText() { return editable; }
    @Override void replaceText(CharSequence value) {
        Editable fresh = tvbox.runtime.EditableText.create(value);
        CharSequence before = editable;
        if (!watchers.isEmpty()) for (var w : watchers) w.beforeTextChanged(before, 0, before.length(), value.length());
        editable = fresh;
        text = fresh;
        if (!watchers.isEmpty()) {
            for (var w : watchers) w.onTextChanged(fresh, 0, before.length(), value.length());
            for (var w : watchers) w.afterTextChanged(fresh);
        }
    }
    @Override android.text.Editable editable() { return editable; }
    public void setSelection(int index) { }
    public void setSelection(int start, int stop) { }
    public void selectAll() { }
    public void extendSelection(int index) { }
    @Override public void tvboxSetValue(Object value) {
        String typed = value == null || value == JSONObject.NULL ? "" : value.toString();
        if (!typed.equals(editable.toString())) setText(typed);
    }
    @Override protected void tvboxDescribe(JSONObject node) throws JSONException {
        super.tvboxDescribe(node);
        int type = getInputType(), variation = type & 0xff0, kind = type & 0xf;
        node.put("type", "input").put("text", editable.toString());
        if (kind == 1 && (variation == 0x80 || variation == 0xe0) || kind == 2 && variation == 0x10) node.put("secure", true);
        if (kind == 2) node.put("keyboard", "number");
        else if (kind == 3) node.put("keyboard", "phone");
        else if (variation == 0x10) node.put("keyboard", "url");
        else if (variation == 0x20 || variation == 0xd0) node.put("keyboard", "email");
        if ((type & 0x20000) != 0) node.put("multiline", true);
        if (!isEnabled()) node.put("enabled", false);
        node.remove("tappable");
    }
}
