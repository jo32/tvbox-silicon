package android.window;

public interface OnBackAnimationCallback extends OnBackInvokedCallback {
    default void onBackStarted(BackEvent backEvent) { }
    default void onBackProgressed(BackEvent backEvent) { }
    default void onBackCancelled() { }
}
