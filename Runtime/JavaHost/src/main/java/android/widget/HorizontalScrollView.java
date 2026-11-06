package android.widget;

import android.content.Context;

public class HorizontalScrollView extends FrameLayout {
    private boolean fillViewport;
    public HorizontalScrollView(Context context) { super(context); }
    public HorizontalScrollView(Context context, android.util.AttributeSet attrs) { super(context); }
    public HorizontalScrollView(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public void setFillViewport(boolean value) { fillViewport = value; }
    public boolean isFillViewport() { return fillViewport; }
    public void setSmoothScrollingEnabled(boolean value) { }
    public final void smoothScrollTo(int x, int y) { scrollTo(x, y); }
    public final void smoothScrollBy(int dx, int dy) { scrollBy(dx, dy); }
    public boolean fullScroll(int direction) { return true; }
    public boolean pageScroll(int direction) { return true; }
    public boolean arrowScroll(int direction) { return true; }
    @Override protected String tvboxAxis() { return "h"; }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException { super.tvboxDescribe(node); node.put("type", "scroll"); }
}
