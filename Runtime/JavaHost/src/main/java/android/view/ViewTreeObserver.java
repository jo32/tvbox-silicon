package android.view;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/** Layout listeners run once a window is shown, which is when Android first lays it out. */
public final class ViewTreeObserver {
    public interface OnGlobalLayoutListener { void onGlobalLayout(); }
    public interface OnScrollChangedListener { void onScrollChanged(); }
    public interface OnPreDrawListener { boolean onPreDraw(); }
    public interface OnGlobalFocusChangeListener { void onGlobalFocusChanged(View oldFocus, View newFocus); }
    public interface OnWindowFocusChangeListener { void onWindowFocusChanged(boolean hasFocus); }
    private final List<OnGlobalLayoutListener> layout = new CopyOnWriteArrayList<>();
    private final List<OnPreDrawListener> preDraw = new CopyOnWriteArrayList<>();

    public void addOnGlobalLayoutListener(OnGlobalLayoutListener listener) { if (listener != null) layout.add(listener); }
    public void removeOnGlobalLayoutListener(OnGlobalLayoutListener listener) { layout.remove(listener); }
    public void removeGlobalOnLayoutListener(OnGlobalLayoutListener listener) { layout.remove(listener); }
    public void addOnPreDrawListener(OnPreDrawListener listener) { if (listener != null) preDraw.add(listener); }
    public void removeOnPreDrawListener(OnPreDrawListener listener) { preDraw.remove(listener); }
    public void addOnScrollChangedListener(OnScrollChangedListener listener) { }
    public void removeOnScrollChangedListener(OnScrollChangedListener listener) { }
    public void addOnGlobalFocusChangeListener(OnGlobalFocusChangeListener listener) { }
    public void removeOnGlobalFocusChangeListener(OnGlobalFocusChangeListener listener) { }
    public void addOnWindowFocusChangeListener(OnWindowFocusChangeListener listener) { }
    public void removeOnWindowFocusChangeListener(OnWindowFocusChangeListener listener) { }
    public boolean isAlive() { return true; }
    public void dispatchOnGlobalLayout() {
        for (OnGlobalLayoutListener listener : layout) {
            try { listener.onGlobalLayout(); } catch (RuntimeException failed) { System.err.println("PLUGIN_WINDOW_ERROR layout " + failed); }
        }
        for (OnPreDrawListener listener : preDraw) {
            try { listener.onPreDraw(); } catch (RuntimeException failed) { System.err.println("PLUGIN_WINDOW_ERROR draw " + failed); }
        }
    }
}
