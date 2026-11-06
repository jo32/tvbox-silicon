package android.view;

public interface ViewParent {
    ViewParent getParent();
    void requestLayout();
    boolean isLayoutRequested();
    void requestDisallowInterceptTouchEvent(boolean disallow);
    void requestChildFocus(View child, View focused);
    void clearChildFocus(View child);
    void bringChildToFront(View child);
    void focusableViewAvailable(View view);
}
