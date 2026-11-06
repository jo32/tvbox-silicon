package android.view;

import android.content.Context;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.os.Handler;
import android.os.Looper;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * A view in a plugin's window. Nothing is laid out or drawn on screen: the app draws the tree from
 * {@link #tvboxNode()} and the viewer's taps and edits come back as {@link #tvboxActivate()} and
 * {@link #tvboxSetValue(Object)}, which run the plugin's own listeners.
 */
public class View implements Drawable.Callback {
    public static final int NO_ID = -1, VISIBLE = 0, INVISIBLE = 4, GONE = 8;
    // android.R.attr state ids, as StateListDrawable and ColorStateList match them.
    static final int STATE_FOCUSED = 16842908, STATE_SELECTED = 16842913, STATE_ENABLED = 16842910,
        STATE_CHECKED = 16842912, STATE_ACTIVATED = 16843518, STATE_PRESSED = 16842919;
    private static final AtomicInteger NEXT_ID = new AtomicInteger(1);
    private static final Handler HANDLER = new Handler(Looper.getMainLooper());
    private static View focusedView;

    public final int tvboxNodeID = tvbox.runtime.PluginWindows.nextID();
    protected Context mContext;
    ViewParent parent;
    private ViewGroup.LayoutParams layoutParams;
    private int id = NO_ID, visibility = VISIBLE, measuredWidth, measuredHeight, left, top, right, bottom, scrollX, scrollY, minWidth, minHeight;
    private int paddingLeft, paddingTop, paddingRight, paddingBottom, systemUiVisibility;
    private boolean enabled = true, clickable, longClickable, focusable, focusableInTouchMode, selected, pressed, activated;
    private float alpha = 1f, scaleX = 1f, scaleY = 1f, translationX, translationY, elevation, rotation, pivotX, pivotY;
    private Object tag;
    private Map<Integer, Object> keyedTags;
    private CharSequence contentDescription;
    private Drawable background;
    private ViewTreeObserver observer;
    OnClickListener clickListener;
    private OnLongClickListener longClickListener;
    private OnFocusChangeListener focusListener;
    private OnKeyListener keyListener;
    private OnTouchListener touchListener;

    public interface OnClickListener { void onClick(View view); }
    public interface OnLongClickListener { boolean onLongClick(View view); }
    public interface OnFocusChangeListener { void onFocusChange(View view, boolean hasFocus); }
    public interface OnKeyListener { boolean onKey(View view, int keyCode, KeyEvent event); }
    public interface OnTouchListener { boolean onTouch(View view, MotionEvent event); }
    public interface OnLayoutChangeListener { void onLayoutChange(View v, int l, int t, int r, int b, int ol, int ot, int or, int ob); }
    public interface OnAttachStateChangeListener { void onViewAttachedToWindow(View v); void onViewDetachedFromWindow(View v); }
    public interface OnSystemUiVisibilityChangeListener { void onSystemUiVisibilityChange(int visibility); }

    public static class MeasureSpec {
        public static final int UNSPECIFIED = 0, EXACTLY = 1 << 30, AT_MOST = 2 << 30;
        private static final int MODE_MASK = 3 << 30;
        public static int makeMeasureSpec(int size, int mode) { return (size & ~MODE_MASK) | (mode & MODE_MASK); }
        public static int getMode(int spec) { return spec & MODE_MASK; }
        public static int getSize(int spec) { return spec & ~MODE_MASK; }
    }

    public View(Context context) { mContext = context; }
    public View(Context context, android.util.AttributeSet attrs) { this(context); }
    public View(Context context, android.util.AttributeSet attrs, int defStyleAttr) { this(context); }
    public View(Context context, android.util.AttributeSet attrs, int defStyleAttr, int defStyleRes) { this(context); }

    public static int generateViewId() { return NEXT_ID.getAndIncrement(); }
    public final Context getContext() { return mContext; }
    public Resources getResources() { return mContext == null ? Resources.getSystem() : mContext.getResources(); }
    public final ViewParent getParent() { return parent; }
    public View getRootView() { View root = this; while (root.parent instanceof View up) root = up; return root; }
    public int getId() { return id; }
    public void setId(int value) { id = value; }
    public Object getTag() { return tag; }
    public void setTag(Object value) { tag = value; }
    public Object getTag(int key) { return keyedTags == null ? null : keyedTags.get(key); }
    public void setTag(int key, Object value) { if (keyedTags == null) keyedTags = new HashMap<>(); keyedTags.put(key, value); }

    public <T extends View> T findViewById(int wanted) { return wanted == NO_ID ? null : tvboxFindBy(v -> v.id == wanted); }
    public <T extends View> T findViewWithTag(Object wanted) { return wanted == null ? null : tvboxFindBy(v -> wanted.equals(v.tag)); }
    @SuppressWarnings("unchecked")
    <T extends View> T tvboxFindBy(java.util.function.Predicate<View> test) { return test.test(this) ? (T) this : null; }
    /** The view with this node id in this tree. */
    public View tvboxFind(int nodeID) { return tvboxFindBy(v -> v.tvboxNodeID == nodeID); }

    public ViewGroup.LayoutParams getLayoutParams() { return layoutParams; }
    public void setLayoutParams(ViewGroup.LayoutParams params) {
        if (params == null) throw new NullPointerException("Layout parameters cannot be null");
        layoutParams = params;
    }
    public int getVisibility() { return visibility; }
    public void setVisibility(int value) { visibility = value; }
    public boolean isShown() { View v = this; while (v != null) { if (v.visibility != VISIBLE) return false; v = v.parent instanceof View up ? up : null; } return true; }
    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean value) { enabled = value; }
    public boolean isClickable() { return clickable; }
    public void setClickable(boolean value) { clickable = value; }
    public boolean isLongClickable() { return longClickable; }
    public void setLongClickable(boolean value) { longClickable = value; }
    public boolean isFocusable() { return focusable; }
    public void setFocusable(boolean value) { focusable = value; }
    public void setFocusable(int value) { focusable = value != 0; }
    public boolean isFocusableInTouchMode() { return focusableInTouchMode; }
    public void setFocusableInTouchMode(boolean value) { focusableInTouchMode = value; if (value) focusable = true; }
    public boolean isSelected() { return selected; }
    public void setSelected(boolean value) { selected = value; }
    public boolean isPressed() { return pressed; }
    public void setPressed(boolean value) { pressed = value; }
    public boolean isActivated() { return activated; }
    public void setActivated(boolean value) { activated = value; }
    public boolean isFocused() { return focusedView == this; }
    public boolean hasFocus() { View v = focusedView; while (v != null) { if (v == this) return true; v = v.parent instanceof View up ? up : null; } return false; }
    public View findFocus() { return hasFocus() ? focusedView : null; }
    public boolean isInTouchMode() { return false; }
    public boolean isAttachedToWindow() { return true; }
    public boolean isLaidOut() { return true; }
    public boolean isHardwareAccelerated() { return false; }
    public boolean isInEditMode() { return false; }

    public final boolean requestFocus() { return requestFocus(130); }
    public final boolean requestFocus(int direction) { return requestFocus(direction, null); }
    public boolean requestFocus(int direction, Rect previouslyFocusedRect) {
        if (focusedView == this) return true;
        View old = focusedView;
        focusedView = this;
        if (old != null && old.focusListener != null) old.focusListener.onFocusChange(old, false);
        if (focusListener != null) focusListener.onFocusChange(this, true);
        return true;
    }
    public void clearFocus() {
        if (focusedView != this) return;
        focusedView = null;
        if (focusListener != null) focusListener.onFocusChange(this, false);
    }

    public void setOnClickListener(OnClickListener listener) { if (!clickable) clickable = true; clickListener = listener; }
    public boolean hasOnClickListeners() { return clickListener != null; }
    public void setOnLongClickListener(OnLongClickListener listener) { longClickable = true; longClickListener = listener; }
    public void setOnFocusChangeListener(OnFocusChangeListener listener) { focusListener = listener; }
    public OnFocusChangeListener getOnFocusChangeListener() { return focusListener; }
    public void setOnKeyListener(OnKeyListener listener) { keyListener = listener; }
    public void setOnTouchListener(OnTouchListener listener) { touchListener = listener; }
    public void setOnSystemUiVisibilityChangeListener(OnSystemUiVisibilityChangeListener listener) { }
    public void addOnLayoutChangeListener(OnLayoutChangeListener listener) { }
    public void removeOnLayoutChangeListener(OnLayoutChangeListener listener) { }
    public void addOnAttachStateChangeListener(OnAttachStateChangeListener listener) { }
    public void removeOnAttachStateChangeListener(OnAttachStateChangeListener listener) { }
    public boolean performClick() {
        if (clickListener == null) return false;
        clickListener.onClick(this);
        return true;
    }
    public boolean callOnClick() { return performClick(); }
    public boolean performLongClick() { return longClickListener != null && longClickListener.onLongClick(this); }

    /** Set by a list on its rows: what tapping the row does (check it, run the item click listener). */
    public Runnable tvboxItemTap;

    /** Whether a tap does anything, which the app shows as a button. */
    public boolean tvboxTappable() {
        return clickListener != null || tvboxItemTap != null || !(this instanceof ViewGroup) && (keyListener != null || touchListener != null);
    }
    /** Whether the plugin reads where on this view the viewer touches (a color wheel), so the app sends the point. */
    public boolean tvboxTouchable() {
        return touchListener != null || tvbox.runtime.PluginWindows.overrides(getClass(), "onTouchEvent", MotionEvent.class);
    }
    /** A tap at (fx, fy), fractions of the view's size: down, move and up there, as Android delivers a touch. */
    public void tvboxTouch(float fx, float fy) {
        float x = Math.max(0, Math.min(1, fx)) * getWidth(), y = Math.max(0, Math.min(1, fy)) * getHeight();
        long now = System.currentTimeMillis();
        dispatchTouchEvent(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0));
        dispatchTouchEvent(MotionEvent.obtain(now, now + 16, MotionEvent.ACTION_MOVE, x, y, 0));
        dispatchTouchEvent(MotionEvent.obtain(now, now + 80, MotionEvent.ACTION_UP, x, y, 0));
    }
    /** A tap or OK press as Android delivers it: focus, then the click, or the key or touch a view listens for. */
    public void tvboxActivate() {
        if (focusable || focusListener != null) requestFocus();
        if (performClick()) return;
        if (tvboxItemTap != null) { tvboxItemTap.run(); return; }
        if (keyListener != null) {
            boolean handled = keyListener.onKey(this, KeyEvent.KEYCODE_DPAD_CENTER, new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER));
            handled |= keyListener.onKey(this, KeyEvent.KEYCODE_DPAD_CENTER, new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER));
            if (handled) return;
        }
        if (touchListener != null) {
            long now = System.currentTimeMillis();
            float x = getWidth() / 2f, y = getHeight() / 2f;
            touchListener.onTouch(this, MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0));
            touchListener.onTouch(this, MotionEvent.obtain(now, now + 80, MotionEvent.ACTION_UP, x, y, 0));
        }
    }
    /** What the viewer typed, switched or dragged; views without a value ignore it. */
    public void tvboxSetValue(Object value) { }
    /** The viewer pressed Return in this field. */
    public void tvboxSubmit() { }

    public boolean post(Runnable action) { return HANDLER.post(action); }
    public boolean postDelayed(Runnable action, long delay) { return HANDLER.postDelayed(action, delay); }
    public boolean removeCallbacks(Runnable action) { HANDLER.removeCallbacks(action); return true; }
    public void postInvalidate() { }
    public void invalidate() { }
    public void requestLayout() { }
    public boolean isLayoutRequested() { return false; }
    public void forceLayout() { }
    public void bringToFront() { }
    public ViewTreeObserver getViewTreeObserver() { if (observer == null) observer = new ViewTreeObserver(); return observer; }
    /** Layout listeners anywhere in the tree, once the window is shown. */
    public void tvboxDispatchLayout() { if (observer != null) observer.dispatchOnGlobalLayout(); }

    public Drawable getBackground() { return background; }
    public void setBackground(Drawable value) { background = value; }
    public void setBackgroundDrawable(Drawable value) { background = value; }
    public void setBackgroundColor(int color) { background = new ColorDrawable(color); }
    public void setBackgroundResource(int id) { if (id == 0) background = null; }
    public void setBackgroundTintList(android.content.res.ColorStateList tint) { }
    public void setForeground(Drawable value) { }
    public void setPadding(int l, int t, int r, int b) { paddingLeft = l; paddingTop = t; paddingRight = r; paddingBottom = b; }
    public void setPaddingRelative(int s, int t, int e, int b) { setPadding(s, t, e, b); }
    public int getPaddingLeft() { return paddingLeft; }
    public int getPaddingTop() { return paddingTop; }
    public int getPaddingRight() { return paddingRight; }
    public int getPaddingBottom() { return paddingBottom; }
    public int getPaddingStart() { return paddingLeft; }
    public int getPaddingEnd() { return paddingRight; }
    public float getAlpha() { return alpha; }
    public void setAlpha(float value) { alpha = value; }
    public float getScaleX() { return scaleX; }
    public float getScaleY() { return scaleY; }
    public void setScaleX(float value) { scaleX = value; }
    public void setScaleY(float value) { scaleY = value; }
    public void setPivotX(float value) { pivotX = value; }
    public void setPivotY(float value) { pivotY = value; }
    public float getPivotX() { return pivotX; }
    public float getPivotY() { return pivotY; }
    public float getTranslationX() { return translationX; }
    public float getTranslationY() { return translationY; }
    public void setTranslationX(float value) { translationX = value; }
    public void setTranslationY(float value) { translationY = value; }
    public void setTranslationZ(float value) { }
    public float getRotation() { return rotation; }
    public void setRotation(float value) { rotation = value; }
    public float getElevation() { return elevation; }
    public void setElevation(float value) { elevation = value; }
    public float getX() { return left + translationX; }
    public float getY() { return top + translationY; }
    public void setX(float value) { translationX = value - left; }
    public void setY(float value) { translationY = value - top; }
    public void setClipToOutline(boolean value) { }
    public void setLayerType(int type, android.graphics.Paint paint) { }
    public void setOverScrollMode(int mode) { }
    public void setHorizontalScrollBarEnabled(boolean value) { }
    public void setVerticalScrollBarEnabled(boolean value) { }
    public void setScrollBarStyle(int style) { }
    public void setFitsSystemWindows(boolean value) { }
    public void setSystemUiVisibility(int value) { systemUiVisibility = value; }
    public int getSystemUiVisibility() { return systemUiVisibility; }
    public void setKeepScreenOn(boolean value) { }
    public void setSoundEffectsEnabled(boolean value) { }
    public void setHapticFeedbackEnabled(boolean value) { }
    public boolean performHapticFeedback(int constant) { return false; }
    public void setDrawingCacheEnabled(boolean value) { }
    public boolean isDrawingCacheEnabled() { return false; }
    public void buildDrawingCache() { }
    public void buildDrawingCache(boolean autoScale) { }
    public void destroyDrawingCache() { }
    public Bitmap getDrawingCache() { return null; }
    public Bitmap getDrawingCache(boolean autoScale) { return null; }
    public void setDrawingCacheBackgroundColor(int color) { }
    public void setWillNotDraw(boolean value) { }
    public void setContentDescription(CharSequence value) { contentDescription = value; }
    public CharSequence getContentDescription() { return contentDescription; }
    public void setImportantForAccessibility(int mode) { }
    public void setNextFocusDownId(int id) { }
    public void setNextFocusUpId(int id) { }
    public void setNextFocusLeftId(int id) { }
    public void setNextFocusRightId(int id) { }
    public void setNextFocusForwardId(int id) { }
    public void setDuplicateParentStateEnabled(boolean value) { }
    public void setMinimumWidth(int value) { minWidth = value; }
    public void setMinimumHeight(int value) { minHeight = value; }
    public int getMinimumWidth() { return minWidth; }
    public int getMinimumHeight() { return minHeight; }
    public WindowInsets getRootWindowInsets() { return new WindowInsets(); }
    public WindowInsets onApplyWindowInsets(WindowInsets insets) { return insets; }
    public void requestApplyInsets() { }
    public android.os.IBinder getWindowToken() { return null; }
    public android.os.IBinder getApplicationWindowToken() { return null; }
    public void getWindowVisibleDisplayFrame(Rect out) { out.set(0, 0, android.util.DisplayMetrics.WIDTH, android.util.DisplayMetrics.HEIGHT); }
    public void getLocationOnScreen(int[] out) { out[0] = left; out[1] = top; }
    public void getLocationInWindow(int[] out) { getLocationOnScreen(out); }
    public boolean getGlobalVisibleRect(Rect out) { out.set(left, top, right, bottom); return true; }
    public void getDrawingRect(Rect out) { out.set(scrollX, scrollY, scrollX + getWidth(), scrollY + getHeight()); }
    public void getHitRect(Rect out) { out.set(left, top, right, bottom); }
    public void scrollTo(int x, int y) { scrollX = x; scrollY = y; }
    public void scrollBy(int x, int y) { scrollTo(scrollX + x, scrollY + y); }
    public int getScrollX() { return scrollX; }
    public int getScrollY() { return scrollY; }
    public boolean canScrollVertically(int direction) { return false; }
    public boolean canScrollHorizontally(int direction) { return false; }
    public boolean dispatchKeyEvent(KeyEvent event) { return keyListener != null && keyListener.onKey(this, event.getKeyCode(), event); }
    public boolean onKeyDown(int keyCode, KeyEvent event) { return false; }
    public boolean onKeyUp(int keyCode, KeyEvent event) { return false; }
    public boolean onTouchEvent(MotionEvent event) { return false; }
    /** The touch listener first, then the view's own onTouchEvent, as Android dispatches a touch. */
    public boolean dispatchTouchEvent(MotionEvent event) {
        if (touchListener != null && enabled && touchListener.onTouch(this, event)) return true;
        return onTouchEvent(event);
    }
    public int[] getDrawableState() {
        java.util.List<Integer> on = new java.util.ArrayList<>();
        if (enabled) on.add(STATE_ENABLED);
        if (isFocused()) on.add(STATE_FOCUSED);
        if (selected) on.add(STATE_SELECTED);
        if (activated) on.add(STATE_ACTIVATED);
        if (pressed) on.add(STATE_PRESSED);
        if (tvboxChecked()) on.add(STATE_CHECKED);
        return on.stream().mapToInt(Integer::intValue).toArray();
    }
    protected boolean tvboxChecked() { return false; }
    public void refreshDrawableState() { }
    @Override public void invalidateDrawable(Drawable who) { }
    @Override public void scheduleDrawable(Drawable who, Runnable what, long when) { }
    @Override public void unscheduleDrawable(Drawable who, Runnable what) { }

    // Measuring and drawing, for plugin views that override them (drawn to a bitmap in tvboxNode).
    public final void measure(int widthSpec, int heightSpec) { onMeasure(widthSpec, heightSpec); }
    protected void onMeasure(int widthSpec, int heightSpec) {
        setMeasuredDimension(getDefaultSize(Math.max(minWidth, 0), widthSpec), getDefaultSize(Math.max(minHeight, 0), heightSpec));
    }
    public static int getDefaultSize(int size, int spec) {
        return switch (MeasureSpec.getMode(spec)) { case MeasureSpec.AT_MOST, MeasureSpec.EXACTLY -> MeasureSpec.getSize(spec); default -> size; };
    }
    public static int resolveSize(int size, int spec) { return resolveSizeAndState(size, spec, 0); }
    public static int resolveSizeAndState(int size, int spec, int childState) {
        int specSize = MeasureSpec.getSize(spec);
        return switch (MeasureSpec.getMode(spec)) { case MeasureSpec.AT_MOST -> Math.min(size, specSize); case MeasureSpec.EXACTLY -> specSize; default -> size; };
    }
    protected final void setMeasuredDimension(int width, int height) { measuredWidth = width; measuredHeight = height; }
    public final int getMeasuredWidth() { return measuredWidth; }
    public final int getMeasuredHeight() { return measuredHeight; }
    protected int getSuggestedMinimumWidth() { return minWidth; }
    protected int getSuggestedMinimumHeight() { return minHeight; }
    public void layout(int l, int t, int r, int b) {
        boolean changed = l != left || t != top || r != right || b != bottom;
        left = l; top = t; right = r; bottom = b;
        if (changed) onSizeChanged(r - l, b - t, 0, 0);
        onLayout(changed, l, t, r, b);
    }
    protected void onLayout(boolean changed, int l, int t, int r, int b) { }
    protected void onSizeChanged(int w, int h, int oldw, int oldh) { }
    protected void onAttachedToWindow() { }
    protected void onDetachedFromWindow() { }
    protected void onFinishInflate() { }
    public void draw(Canvas canvas) { if (background != null) background.draw(canvas); onDraw(canvas); dispatchDraw(canvas); }
    protected void onDraw(Canvas canvas) { }
    protected void dispatchDraw(Canvas canvas) { }
    public final int getLeft() { return left; }
    public final int getTop() { return top; }
    public final int getRight() { return right; }
    public final int getBottom() { return bottom; }
    public final int getWidth() { return right - left > 0 ? right - left : layoutParams != null && layoutParams.width > 0 ? layoutParams.width : measuredWidth; }
    public final int getHeight() { return bottom - top > 0 ? bottom - top : layoutParams != null && layoutParams.height > 0 ? layoutParams.height : measuredHeight; }

    // What the app draws.
    /** This view and what it holds, or null when it is hidden. */
    public final JSONObject tvboxNode() throws JSONException {
        if (visibility != VISIBLE) return null;
        JSONObject node = new JSONObject().put("id", tvboxNodeID).put("type", "view");
        if (!enabled) node.put("enabled", false);
        if (selected || activated) node.put("selected", true);
        if (isFocused()) node.put("focused", true);
        if (alpha < 0.99f) node.put("alpha", alpha);
        if (tvboxTappable()) node.put("tappable", true);
        Integer fill = background == null ? null : background.tvboxColor(getDrawableState());
        if (fill != null && (fill >>> 24) != 0) node.put("background", tvbox.runtime.PluginWindows.hex(fill));
        float density = getResources().getDisplayMetrics().density;
        if ((paddingLeft | paddingTop | paddingRight | paddingBottom) != 0) {
            node.put("padding", new org.json.JSONArray().put(Math.round(paddingLeft / density)).put(Math.round(paddingTop / density))
                .put(Math.round(paddingRight / density)).put(Math.round(paddingBottom / density)));
        }
        if (layoutParams != null) {
            if (layoutParams.width > 0) node.put("width", Math.round(layoutParams.width / density));
            if (layoutParams.height > 0) node.put("height", Math.round(layoutParams.height / density));
            if (layoutParams.width == ViewGroup.LayoutParams.MATCH_PARENT) node.put("fillWidth", true);
            if (layoutParams instanceof android.widget.LinearLayout.LayoutParams linear && linear.weight > 0) node.put("weight", linear.weight);
        }
        tvboxDescribe(node);
        return node;
    }
    /** Adds what this kind of view shows; plugin subclasses that draw themselves are drawn here. */
    protected void tvboxDescribe(JSONObject node) throws JSONException {
        if (!tvbox.runtime.PluginWindows.drawsItself(getClass())) return;
        int width = getWidth(), height = getHeight();
        if (width <= 0 || height <= 0) {
            measure(MeasureSpec.makeMeasureSpec(600, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(600, MeasureSpec.AT_MOST));
            width = getMeasuredWidth(); height = getMeasuredHeight();
        }
        if (width <= 0 || height <= 0 || width > 2000 || height > 2000) return;
        if (right - left != width || bottom - top != height) layout(0, 0, width, height);
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        draw(new Canvas(bitmap));
        node.put("type", "image").put("image", tvbox.runtime.PluginWindows.png(bitmap, false));
        if (enabled && tvboxTouchable()) node.put("touch", true);
        float density = getResources().getDisplayMetrics().density;
        node.put("width", Math.round(width / density)).put("height", Math.round(height / density));
    }
}
