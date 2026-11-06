package android.window;

public final class BackEvent {
    public static final int EDGE_LEFT = 0, EDGE_RIGHT = 1, EDGE_NONE = 2;
    private final float touchX, touchY, progress;
    private final int swipeEdge;
    public BackEvent(float touchX, float touchY, float progress, int swipeEdge) { this.touchX = touchX; this.touchY = touchY; this.progress = progress; this.swipeEdge = swipeEdge; }
    public float getTouchX() { return touchX; }
    public float getTouchY() { return touchY; }
    public float getProgress() { return progress; }
    public int getSwipeEdge() { return swipeEdge; }
    public long getFrameTimeMillis() { return System.currentTimeMillis(); }
}
