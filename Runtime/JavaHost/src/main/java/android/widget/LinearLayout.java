package android.widget;

import android.content.Context;
import android.view.ViewGroup;

public class LinearLayout extends ViewGroup {
    public static final int HORIZONTAL = 0, VERTICAL = 1, SHOW_DIVIDER_NONE = 0, SHOW_DIVIDER_MIDDLE = 2;
    private int orientation = HORIZONTAL, gravity = 0x800033;
    private float weightSum = -1f;

    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public float weight;
        public int gravity = -1;
        public LayoutParams(int width, int height) { super(width, height); }
        public LayoutParams(int width, int height, float weight) { super(width, height); this.weight = weight; }
        public LayoutParams(ViewGroup.LayoutParams source) {
            super(source);
            if (source instanceof LayoutParams linear) { weight = linear.weight; gravity = linear.gravity; }
        }
        public LayoutParams(ViewGroup.MarginLayoutParams source) { this((ViewGroup.LayoutParams) source); }
        public LayoutParams(LayoutParams source) { this((ViewGroup.LayoutParams) source); }
        public LayoutParams(Context context, android.util.AttributeSet attrs) { super(context, attrs); }
    }

    public LinearLayout(Context context) { super(context); }
    public LinearLayout(Context context, android.util.AttributeSet attrs) { super(context); }
    public LinearLayout(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public LinearLayout(Context context, android.util.AttributeSet attrs, int defStyleAttr, int defStyleRes) { super(context); }

    public int getOrientation() { return orientation; }
    public void setOrientation(int value) { orientation = value; }
    public int getGravity() { return gravity; }
    public void setGravity(int value) { gravity = value; }
    public void setHorizontalGravity(int value) { gravity = (gravity & ~0x800007) | (value & 0x800007); }
    public void setVerticalGravity(int value) { gravity = (gravity & ~0x70) | (value & 0x70); }
    public float getWeightSum() { return weightSum; }
    public void setWeightSum(float value) { weightSum = value; }
    public void setBaselineAligned(boolean value) { }
    public void setShowDividers(int value) { }
    public void setDividerDrawable(android.graphics.drawable.Drawable divider) { }
    public void setDividerPadding(int value) { }
    @Override protected void onMeasure(int widthSpec, int heightSpec) { super.onMeasure(widthSpec, heightSpec); }
    @Override protected ViewGroup.LayoutParams generateDefaultLayoutParams() {
        return orientation == VERTICAL ? new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT) : new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
    }
    @Override protected ViewGroup.LayoutParams generateLayoutParams(ViewGroup.LayoutParams params) { return new LayoutParams(params); }
    @Override public ViewGroup.LayoutParams generateLayoutParams(android.util.AttributeSet attrs) { return generateDefaultLayoutParams(); }
    @Override protected boolean checkLayoutParams(ViewGroup.LayoutParams params) { return params instanceof LayoutParams; }
    @Override protected String tvboxAxis() { return orientation == VERTICAL ? "v" : "h"; }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        super.tvboxDescribe(node);
        node.put("gravity", gravity);
    }
}
