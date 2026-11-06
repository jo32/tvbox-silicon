package android.content.res;

/** Colors by view state (android.R.attr.state_* ids; a negative id means the state must be off). */
public class ColorStateList {
    private final int[][] states;
    private final int[] colors;
    public ColorStateList(int[][] states, int[] colors) { this.states = states; this.colors = colors; }
    public static ColorStateList valueOf(int color) { return new ColorStateList(new int[][]{new int[0]}, new int[]{color}); }
    public int getDefaultColor() { return colors.length == 0 ? 0xFF000000 : colorForState(new int[0], colors[colors.length - 1]); }
    public int getColorForState(int[] state, int fallback) { return colorForState(state == null ? new int[0] : state, fallback); }
    private int colorForState(int[] state, int fallback) {
        for (int i = 0; i < states.length && i < colors.length; i++) if (android.graphics.drawable.StateListDrawable.matches(states[i], state)) return colors[i];
        return fallback;
    }
    public boolean isStateful() { return states.length > 1; }
    public ColorStateList withAlpha(int alpha) {
        int[] changed = colors.clone();
        for (int i = 0; i < changed.length; i++) changed[i] = (changed[i] & 0xFFFFFF) | (alpha << 24);
        return new ColorStateList(states, changed);
    }
}
