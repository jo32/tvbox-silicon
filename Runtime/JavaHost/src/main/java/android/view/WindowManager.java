package android.view;

/** The display plugins size their windows from; views they add to it directly are not shown. */
public interface WindowManager {
    Display getDefaultDisplay();
    void addView(View view, ViewGroup.LayoutParams params);
    void updateViewLayout(View view, ViewGroup.LayoutParams params);
    void removeView(View view);
    void removeViewImmediate(View view);

    WindowManager DEFAULT = new WindowManager() {
        private final Display display = new Display();
        @Override public Display getDefaultDisplay() { return display; }
        @Override public void addView(View view, ViewGroup.LayoutParams params) { }
        @Override public void updateViewLayout(View view, ViewGroup.LayoutParams params) { }
        @Override public void removeView(View view) { }
        @Override public void removeViewImmediate(View view) { }
    };

    class LayoutParams extends ViewGroup.LayoutParams {
        public static final int TYPE_APPLICATION = 2, FLAG_DIM_BEHIND = 0x2, FLAG_NOT_FOCUSABLE = 0x8,
            FLAG_FULLSCREEN = 0x400, FLAG_KEEP_SCREEN_ON = 0x80, FLAG_LAYOUT_NO_LIMITS = 0x200,
            SOFT_INPUT_ADJUST_RESIZE = 0x10, SOFT_INPUT_STATE_VISIBLE = 0x4, SOFT_INPUT_STATE_HIDDEN = 0x2;
        public int x, y, type = TYPE_APPLICATION, flags, gravity, softInputMode, format, windowAnimations, layoutInDisplayCutoutMode;
        public float dimAmount = 0.6f, alpha = 1f, horizontalMargin, verticalMargin;
        public LayoutParams() { super(MATCH_PARENT, MATCH_PARENT); }
        public LayoutParams(int width, int height) { super(width, height); }
        public LayoutParams(int type) { this(); this.type = type; }
        public LayoutParams(int width, int height, int type, int flags, int format) { super(width, height); this.type = type; this.flags = flags; this.format = format; }
        public final int copyFrom(LayoutParams other) {
            width = other.width; height = other.height; x = other.x; y = other.y; type = other.type; flags = other.flags;
            gravity = other.gravity; softInputMode = other.softInputMode; dimAmount = other.dimAmount; alpha = other.alpha;
            return 0;
        }
    }
}
