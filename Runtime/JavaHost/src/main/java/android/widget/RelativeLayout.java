package android.widget;

import android.content.Context;
import android.view.ViewGroup;

/** Children positioned by rules; the app shows them down the screen in the order they were added. */
public class RelativeLayout extends ViewGroup {
    public static final int TRUE = -1;
    public static final int LEFT_OF = 0, RIGHT_OF = 1, ABOVE = 2, BELOW = 3, ALIGN_BASELINE = 4, ALIGN_LEFT = 5, ALIGN_TOP = 6, ALIGN_RIGHT = 7, ALIGN_BOTTOM = 8,
        ALIGN_PARENT_LEFT = 9, ALIGN_PARENT_TOP = 10, ALIGN_PARENT_RIGHT = 11, ALIGN_PARENT_BOTTOM = 12, CENTER_IN_PARENT = 13, CENTER_HORIZONTAL = 14, CENTER_VERTICAL = 15,
        START_OF = 16, END_OF = 17, ALIGN_START = 18, ALIGN_END = 19, ALIGN_PARENT_START = 20, ALIGN_PARENT_END = 21;
    private int gravity = 0x800033;

    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        private final int[] rules = new int[22];
        public boolean alignWithParent;
        public LayoutParams(int width, int height) { super(width, height); }
        public LayoutParams(ViewGroup.LayoutParams source) { super(source); }
        public LayoutParams(ViewGroup.MarginLayoutParams source) { super(source); }
        public LayoutParams(LayoutParams source) { super((ViewGroup.MarginLayoutParams) source); System.arraycopy(source.rules, 0, rules, 0, rules.length); }
        public LayoutParams(Context context, android.util.AttributeSet attrs) { super(context, attrs); }
        public void addRule(int verb) { addRule(verb, TRUE); }
        public void addRule(int verb, int subject) { if (verb >= 0 && verb < rules.length) rules[verb] = subject; }
        public void removeRule(int verb) { addRule(verb, 0); }
        public int getRule(int verb) { return verb >= 0 && verb < rules.length ? rules[verb] : 0; }
        public int[] getRules() { return rules; }
    }

    public RelativeLayout(Context context) { super(context); }
    public RelativeLayout(Context context, android.util.AttributeSet attrs) { super(context); }
    public RelativeLayout(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public void setGravity(int value) { gravity = value; }
    public int getGravity() { return gravity; }
    public void setHorizontalGravity(int value) { gravity = (gravity & ~0x800007) | (value & 0x800007); }
    public void setVerticalGravity(int value) { gravity = (gravity & ~0x70) | (value & 0x70); }
    public void setIgnoreGravity(int viewId) { }
    @Override protected ViewGroup.LayoutParams generateDefaultLayoutParams() { return new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT); }
    @Override protected ViewGroup.LayoutParams generateLayoutParams(ViewGroup.LayoutParams params) { return new LayoutParams(params); }
    @Override public ViewGroup.LayoutParams generateLayoutParams(android.util.AttributeSet attrs) { return generateDefaultLayoutParams(); }
    @Override protected boolean checkLayoutParams(ViewGroup.LayoutParams params) { return params instanceof LayoutParams; }
    @Override protected String tvboxAxis() { return "v"; }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        super.tvboxDescribe(node);
        node.put("gravity", gravity);
    }
}
