package android.graphics.drawable;

import android.graphics.Canvas;
import java.util.ArrayList;
import java.util.List;

public class StateListDrawable extends Drawable {
    private final List<int[]> specs = new ArrayList<>();
    private final List<Drawable> drawables = new ArrayList<>();
    public StateListDrawable() { }
    public void addState(int[] stateSet, Drawable drawable) { specs.add(stateSet == null ? new int[0] : stateSet); drawables.add(drawable); }
    public int getStateCount() { return specs.size(); }
    @Override public boolean isStateful() { return true; }
    @Override public Drawable getCurrent() { Drawable found = pick(getState()); return found == null ? this : found; }
    @Override public void draw(Canvas canvas) { Drawable found = pick(getState()); if (found != null) found.draw(canvas); }
    @Override public Integer tvboxColor(int[] viewState) { Drawable found = pick(viewState); return found == null ? null : found.tvboxColor(viewState); }
    private Drawable pick(int[] state) {
        for (int i = 0; i < specs.size(); i++) if (matches(specs.get(i), state)) return drawables.get(i);
        return null;
    }
    /** Android's StateSet.stateSetMatches: every positive id is on, every negative one off. */
    public static boolean matches(int[] spec, int[] state) {
        for (int wanted : spec) {
            if (wanted == 0) break;
            boolean on = false;
            for (int s : state) if (s == Math.abs(wanted)) { on = true; break; }
            if (wanted > 0 != on) return false;
        }
        return true;
    }
}
