package android.view;

import android.content.Context;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Predicate;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public abstract class ViewGroup extends View implements ViewParent {
    public static final int FOCUS_BEFORE_DESCENDANTS = 0x20000, FOCUS_AFTER_DESCENDANTS = 0x40000, FOCUS_BLOCK_DESCENDANTS = 0x60000;
    private final List<View> children = new ArrayList<>();

    public static class LayoutParams {
        public static final int MATCH_PARENT = -1, FILL_PARENT = -1, WRAP_CONTENT = -2;
        public int width, height;
        public LayoutParams(int width, int height) { this.width = width; this.height = height; }
        public LayoutParams(LayoutParams source) { this(source.width, source.height); }
        public LayoutParams(Context context, android.util.AttributeSet attrs) { this(WRAP_CONTENT, WRAP_CONTENT); }
    }

    public static class MarginLayoutParams extends LayoutParams {
        public int leftMargin, topMargin, rightMargin, bottomMargin;
        public MarginLayoutParams(int width, int height) { super(width, height); }
        public MarginLayoutParams(LayoutParams source) {
            super(source);
            if (source instanceof MarginLayoutParams m) setMargins(m.leftMargin, m.topMargin, m.rightMargin, m.bottomMargin);
        }
        public MarginLayoutParams(MarginLayoutParams source) { this((LayoutParams) source); }
        public MarginLayoutParams(Context context, android.util.AttributeSet attrs) { super(context, attrs); }
        public void setMargins(int left, int top, int right, int bottom) { leftMargin = left; topMargin = top; rightMargin = right; bottomMargin = bottom; }
        public void setMarginStart(int value) { leftMargin = value; }
        public void setMarginEnd(int value) { rightMargin = value; }
        public int getMarginStart() { return leftMargin; }
        public int getMarginEnd() { return rightMargin; }
    }

    public interface OnHierarchyChangeListener { void onChildViewAdded(View parent, View child); void onChildViewRemoved(View parent, View child); }

    public ViewGroup(Context context) { super(context); }
    public ViewGroup(Context context, android.util.AttributeSet attrs) { super(context); }
    public ViewGroup(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }

    public int getChildCount() { return children.size(); }
    public View getChildAt(int index) { return index < 0 || index >= children.size() ? null : children.get(index); }
    public int indexOfChild(View child) { return children.indexOf(child); }
    public void addView(View child) { addView(child, -1); }
    public void addView(View child, int index) {
        if (child == null) throw new IllegalArgumentException("Cannot add a null child view to a ViewGroup");
        LayoutParams params = child.getLayoutParams();
        addView(child, index, params == null ? generateDefaultLayoutParams() : params);
    }
    public void addView(View child, int width, int height) {
        LayoutParams params = generateDefaultLayoutParams();
        params.width = width; params.height = height;
        addView(child, -1, params);
    }
    public void addView(View child, LayoutParams params) { addView(child, -1, params); }
    public void addView(View child, int index, LayoutParams params) {
        if (child == null) throw new IllegalArgumentException("Cannot add a null child view to a ViewGroup");
        if (child.parent != null) throw new IllegalStateException("The specified child already has a parent. You must call removeView() on the child's parent first.");
        if (params == null) params = generateDefaultLayoutParams();
        if (!checkLayoutParams(params)) params = generateLayoutParams(params);
        child.setLayoutParams(params);
        child.parent = this;
        if (index < 0 || index > children.size()) children.add(child); else children.add(index, child);
        onViewAdded(child);
    }
    protected boolean addViewInLayout(View child, int index, LayoutParams params) { addView(child, index, params); return true; }
    protected void onViewAdded(View child) { }
    protected void onViewRemoved(View child) { }
    public void removeView(View child) { if (children.remove(child)) { child.parent = null; onViewRemoved(child); } }
    public void removeViewInLayout(View child) { removeView(child); }
    public void removeViewAt(int index) { View child = getChildAt(index); if (child != null) removeView(child); }
    public void removeViews(int start, int count) { for (int i = 0; i < count; i++) removeViewAt(start); }
    public void removeAllViews() { for (View child : new ArrayList<>(children)) removeView(child); }
    public void removeAllViewsInLayout() { removeAllViews(); }
    public void updateViewLayout(View view, LayoutParams params) { view.setLayoutParams(params); }
    protected LayoutParams generateDefaultLayoutParams() { return new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT); }
    protected LayoutParams generateLayoutParams(LayoutParams params) { return params; }
    public LayoutParams generateLayoutParams(android.util.AttributeSet attrs) { return generateDefaultLayoutParams(); }
    protected boolean checkLayoutParams(LayoutParams params) { return params != null; }
    public void setClipChildren(boolean value) { }
    public void setClipToPadding(boolean value) { }
    public void setDescendantFocusability(int value) { }
    public int getDescendantFocusability() { return FOCUS_BEFORE_DESCENDANTS; }
    public void setMotionEventSplittingEnabled(boolean value) { }
    public void setLayoutTransition(Object transition) { }
    public void setOnHierarchyChangeListener(OnHierarchyChangeListener listener) { }
    public boolean onInterceptTouchEvent(MotionEvent event) { return false; }
    public View getFocusedChild() { for (View child : children) if (child.hasFocus()) return child; return null; }
    protected void measureChildren(int widthSpec, int heightSpec) { for (View child : children) child.measure(widthSpec, heightSpec); }
    protected void measureChild(View child, int widthSpec, int heightSpec) { child.measure(widthSpec, heightSpec); }
    protected void measureChildWithMargins(View child, int widthSpec, int widthUsed, int heightSpec, int heightUsed) { child.measure(widthSpec, heightSpec); }

    @Override public void requestChildFocus(View child, View focused) { }
    @Override public void clearChildFocus(View child) { }
    @Override public void requestDisallowInterceptTouchEvent(boolean disallow) { }
    @Override public void bringChildToFront(View child) { if (children.remove(child)) children.add(child); }
    @Override public void focusableViewAvailable(View view) { }
    @Override protected void onLayout(boolean changed, int l, int t, int r, int b) { }

    @Override <T extends View> T tvboxFindBy(Predicate<View> test) {
        T self = super.tvboxFindBy(test);
        if (self != null) return self;
        for (View child : new ArrayList<>(children)) { T found = child.tvboxFindBy(test); if (found != null) return found; }
        return null;
    }
    @Override public void tvboxDispatchLayout() {
        super.tvboxDispatchLayout();
        for (View child : new ArrayList<>(children)) child.tvboxDispatchLayout();
    }
    /** Children laid out down the screen unless a subclass says otherwise. */
    protected String tvboxAxis() { return "z"; }
    @Override protected void tvboxDescribe(JSONObject node) throws JSONException {
        node.put("type", "stack").put("axis", tvboxAxis());
        JSONArray list = new JSONArray();
        for (View child : new ArrayList<>(children)) { JSONObject described = child.tvboxNode(); if (described != null) list.put(described); }
        node.put("children", list);
    }
}
