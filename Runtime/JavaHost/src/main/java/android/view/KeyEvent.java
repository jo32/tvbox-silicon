package android.view;

/** Remote key presses: the host sends OK to views that only listen for keys, and Back to windows. */
public class KeyEvent {
    public static final int ACTION_DOWN = 0, ACTION_UP = 1, ACTION_MULTIPLE = 2,
        KEYCODE_BACK = 4, KEYCODE_DPAD_UP = 19, KEYCODE_DPAD_DOWN = 20, KEYCODE_DPAD_LEFT = 21, KEYCODE_DPAD_RIGHT = 22,
        KEYCODE_DPAD_CENTER = 23, KEYCODE_ENTER = 66, KEYCODE_MENU = 82, KEYCODE_NUMPAD_ENTER = 160;
    private final int action, code;
    private final long time = System.currentTimeMillis();
    public KeyEvent(int action, int code) { this.action = action; this.code = code; }
    public final int getAction() { return action; }
    public final int getKeyCode() { return code; }
    public final int getRepeatCount() { return 0; }
    public final int getMetaState() { return 0; }
    public final long getEventTime() { return time; }
    public final long getDownTime() { return time; }
    public final boolean isLongPress() { return false; }
    public final boolean isCanceled() { return false; }
    public final boolean isShiftPressed() { return false; }
    public int getUnicodeChar() { return 0; }
    public final int getSource() { return 0x101; }
    public static boolean isConfirmKey(int code) { return code == KEYCODE_DPAD_CENTER || code == KEYCODE_ENTER || code == KEYCODE_NUMPAD_ENTER; }
}
