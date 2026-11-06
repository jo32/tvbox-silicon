package android.view;

/** A tap, sent to views that only listen for touches. */
public final class MotionEvent {
    public static final int ACTION_DOWN = 0, ACTION_UP = 1, ACTION_MOVE = 2, ACTION_CANCEL = 3, ACTION_MASK = 0xff;
    private final int action;
    private final float x, y;
    private final long down, time;
    private MotionEvent(long down, long time, int action, float x, float y) { this.down = down; this.time = time; this.action = action; this.x = x; this.y = y; }
    public static MotionEvent obtain(long downTime, long eventTime, int action, float x, float y, int metaState) { return new MotionEvent(downTime, eventTime, action, x, y); }
    public int getAction() { return action; }
    public int getActionMasked() { return action & ACTION_MASK; }
    public int getActionIndex() { return 0; }
    public float getX() { return x; }
    public float getY() { return y; }
    public float getX(int pointer) { return x; }
    public float getY(int pointer) { return y; }
    public float getRawX() { return x; }
    public float getRawY() { return y; }
    public int getPointerCount() { return 1; }
    public int getPointerId(int index) { return 0; }
    public long getDownTime() { return down; }
    public long getEventTime() { return time; }
    public void recycle() { }
}
