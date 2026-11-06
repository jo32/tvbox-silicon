package android.widget;

import android.content.Context;
import android.view.ViewGroup;

public class FrameLayout extends ViewGroup {
    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public static final int UNSPECIFIED_GRAVITY = -1;
        public int gravity = UNSPECIFIED_GRAVITY;
        public LayoutParams(int width, int height) { super(width, height); }
        public LayoutParams(int width, int height, int gravity) { super(width, height); this.gravity = gravity; }
        public LayoutParams(ViewGroup.LayoutParams source) { super(source); if (source instanceof LayoutParams frame) gravity = frame.gravity; }
        public LayoutParams(ViewGroup.MarginLayoutParams source) { this((ViewGroup.LayoutParams) source); }
        public LayoutParams(LayoutParams source) { this((ViewGroup.LayoutParams) source); }
        public LayoutParams(Context context, android.util.AttributeSet attrs) { super(context, attrs); }
    }

    public FrameLayout(Context context) { super(context); }
    public FrameLayout(Context context, android.util.AttributeSet attrs) { super(context); }
    public FrameLayout(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public void setForegroundGravity(int gravity) { }
    public void setMeasureAllChildren(boolean value) { }
    @Override protected ViewGroup.LayoutParams generateDefaultLayoutParams() { return new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT); }
    @Override protected ViewGroup.LayoutParams generateLayoutParams(ViewGroup.LayoutParams params) { return new LayoutParams(params); }
    @Override protected boolean checkLayoutParams(ViewGroup.LayoutParams params) { return params instanceof LayoutParams; }
}
