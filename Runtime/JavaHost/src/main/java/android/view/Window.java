package android.view;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.widget.FrameLayout;

/** A dialog's or the Activity's window: its content and the attributes plugins set (all only kept). */
public class Window {
    public static final int FEATURE_NO_TITLE = 1;
    private final Context context;
    private FrameLayout decor;
    private WindowManager.LayoutParams attributes = new WindowManager.LayoutParams();
    private Drawable background;

    public Window(Context context) { this.context = context; }
    public final Context getContext() { return context; }
    public View getDecorView() {
        if (decor == null) decor = new FrameLayout(context);
        return decor;
    }
    public View peekDecorView() { return decor; }
    /** The content plugins set, or null. */
    public View tvboxContent() { return decor == null || decor.getChildCount() == 0 ? null : decor.getChildAt(0); }
    public void setContentView(View view) {
        FrameLayout root = (FrameLayout) getDecorView();
        root.removeAllViews();
        if (view != null) {
            if (view.getParent() instanceof ViewGroup parent) parent.removeView(view);
            root.addView(view);
        }
    }
    public void setContentView(View view, ViewGroup.LayoutParams params) { if (view != null) view.setLayoutParams(params); setContentView(view); }
    public View findViewById(int id) { return decor == null ? null : decor.findViewById(id); }
    public View getCurrentFocus() { return null; }
    public WindowManager.LayoutParams getAttributes() { return attributes; }
    public void setAttributes(WindowManager.LayoutParams value) { if (value != null) attributes = value; }
    public void setLayout(int width, int height) { attributes.width = width; attributes.height = height; }
    public void setGravity(int gravity) { attributes.gravity = gravity; }
    public void setDimAmount(float amount) { attributes.dimAmount = amount; }
    public void setBackgroundDrawable(Drawable drawable) { background = drawable; }
    public void setBackgroundDrawableResource(int id) { }
    public Drawable tvboxBackground() { return background; }
    public void addFlags(int flags) { attributes.flags |= flags; }
    public void clearFlags(int flags) { attributes.flags &= ~flags; }
    public void setFlags(int flags, int mask) { attributes.flags = (attributes.flags & ~mask) | (flags & mask); }
    public void setSoftInputMode(int mode) { attributes.softInputMode = mode; }
    public void setType(int type) { attributes.type = type; }
    public void setWindowAnimations(int resource) { }
    public void setStatusBarColor(int color) { }
    public void setNavigationBarColor(int color) { }
    public void setNavigationBarContrastEnforced(boolean enforced) { }
    public void setStatusBarContrastEnforced(boolean enforced) { }
    public void setDecorFitsSystemWindows(boolean fits) { }
    public boolean requestFeature(int feature) { return true; }
    public WindowManager getWindowManager() { return WindowManager.DEFAULT; }

    private final java.util.List<Object[]> backCallbacks = new java.util.ArrayList<>();
    private final android.window.OnBackInvokedDispatcher backDispatcher = new android.window.OnBackInvokedDispatcher() {
        @Override public void registerOnBackInvokedCallback(int priority, android.window.OnBackInvokedCallback callback) {
            if (callback == null || priority < 0) return;
            unregisterOnBackInvokedCallback(callback);
            backCallbacks.add(new Object[]{priority, callback});
        }
        @Override public void unregisterOnBackInvokedCallback(android.window.OnBackInvokedCallback callback) { backCallbacks.removeIf(entry -> entry[1] == callback); }
    };
    public android.window.OnBackInvokedDispatcher getOnBackInvokedDispatcher() { return backDispatcher; }
    /** Back to the callback registered last at the highest priority, as Android 13 sends it; false when none is. */
    public boolean tvboxBackCallback() {
        Object[] chosen = null;
        for (Object[] entry : backCallbacks) if (chosen == null || (Integer) entry[0] >= (Integer) chosen[0]) chosen = entry;
        if (chosen == null) return false;
        android.window.OnBackInvokedCallback callback = (android.window.OnBackInvokedCallback) chosen[1];
        if (callback instanceof android.window.OnBackAnimationCallback animated) animated.onBackStarted(new android.window.BackEvent(0, 0, 0, android.window.BackEvent.EDGE_LEFT));
        callback.onBackInvoked();
        return true;
    }
}
