package android.widget;

import android.content.Context;

public class Button extends TextView {
    public Button(Context context) { super(context); setGravity(17); setFocusable(true); setClickable(true); }
    public Button(Context context, android.util.AttributeSet attrs) { this(context); }
    public Button(Context context, android.util.AttributeSet attrs, int defStyleAttr) { this(context); }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        super.tvboxDescribe(node);
        node.put("type", "button");
    }
}
