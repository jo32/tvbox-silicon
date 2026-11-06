package android.view.inputmethod;

/** The app shows its own keyboard when the viewer edits a field. */
public final class InputMethodManager {
    public static final int SHOW_IMPLICIT = 1, SHOW_FORCED = 2, HIDE_IMPLICIT_ONLY = 1, HIDE_NOT_ALWAYS = 2;
    public boolean showSoftInput(android.view.View view, int flags) { return true; }
    public boolean hideSoftInputFromWindow(android.os.IBinder token, int flags) { return true; }
    public void toggleSoftInput(int showFlags, int hideFlags) { }
    public boolean isActive() { return false; }
    public boolean isActive(android.view.View view) { return false; }
    public void restartInput(android.view.View view) { }
}
