package android.view;

public class ViewConfiguration {
    private static final ViewConfiguration DEFAULT = new ViewConfiguration();
    public static ViewConfiguration get(android.content.Context context) { return DEFAULT; }
    public int getScaledTouchSlop() { return 16; }
    public int getScaledMinimumFlingVelocity() { return 100; }
    public int getScaledMaximumFlingVelocity() { return 16000; }
    public int getScaledPagingTouchSlop() { return 32; }
    public static int getLongPressTimeout() { return 500; }
    public static int getTapTimeout() { return 100; }
    public static int getDoubleTapTimeout() { return 300; }
    public static int getTouchSlop() { return 8; }
    public boolean hasPermanentMenuKey() { return false; }
}
