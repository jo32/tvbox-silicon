package android.animation;

import android.os.Handler;
import android.os.Looper;
import java.util.ArrayList;

/**
 * Animates values from the first to the last given. Update listeners hear the end value as soon as the
 * animation starts (so what the app draws next is the finished state); the end callback follows after the
 * duration, capped at a second, on the main looper. Endless animations (a spinner) start and never end.
 */
public class ValueAnimator extends Animator {
    public static final int RESTART = 1, REVERSE = 2, INFINITE = -1;
    public interface AnimatorUpdateListener { void onAnimationUpdate(ValueAnimator animation); }
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private long duration = 300, startDelay;
    private int repeatCount, repeatMode = RESTART;
    private TimeInterpolator interpolator;
    private ArrayList<AnimatorUpdateListener> updates;
    float[] floats;
    int[] ints;
    Object[] objects;
    private TypeEvaluator<?> evaluator;
    private boolean argb, running, started;
    private float fraction;
    private Runnable pendingEnd;

    public ValueAnimator() { }
    public static ValueAnimator ofFloat(float... values) { ValueAnimator a = new ValueAnimator(); a.setFloatValues(values); return a; }
    public static ValueAnimator ofInt(int... values) { ValueAnimator a = new ValueAnimator(); a.setIntValues(values); return a; }
    public static ValueAnimator ofArgb(int... values) { ValueAnimator a = ofInt(values); a.argb = true; return a; }
    public static ValueAnimator ofObject(TypeEvaluator evaluator, Object... values) { ValueAnimator a = new ValueAnimator(); a.setObjectValues(values); a.evaluator = evaluator; return a; }
    public void setFloatValues(float... values) { floats = values; ints = null; objects = null; }
    public void setIntValues(int... values) { ints = values; floats = null; objects = null; }
    public void setObjectValues(Object... values) { objects = values; floats = null; ints = null; }
    public void setEvaluator(TypeEvaluator value) { evaluator = value; }

    @Override public ValueAnimator setDuration(long value) { if (value < 0) throw new IllegalArgumentException("Animators cannot have negative duration: " + value); duration = value; return this; }
    @Override public long getDuration() { return duration; }
    @Override public long getStartDelay() { return startDelay; }
    @Override public void setStartDelay(long value) { startDelay = Math.max(0, value); }
    @Override public void setInterpolator(TimeInterpolator value) { interpolator = value; }
    @Override public TimeInterpolator getInterpolator() { return interpolator; }
    public void setRepeatCount(int value) { repeatCount = value; }
    public int getRepeatCount() { return repeatCount; }
    public void setRepeatMode(int value) { repeatMode = value; }
    public int getRepeatMode() { return repeatMode; }
    public static long getFrameDelay() { return 10; }
    public static void setFrameDelay(long delay) { }
    public static boolean areAnimatorsEnabled() { return true; }
    public void addUpdateListener(AnimatorUpdateListener listener) { if (updates == null) updates = new ArrayList<>(); updates.add(listener); }
    public void removeUpdateListener(AnimatorUpdateListener listener) { if (updates != null) updates.remove(listener); }
    public void removeAllUpdateListeners() { updates = null; }
    public float getAnimatedFraction() { return fraction; }
    public long getCurrentPlayTime() { return (long) (fraction * duration); }
    public void setCurrentPlayTime(long time) { setCurrentFraction(duration <= 0 ? 1 : Math.min(1f, time / (float) duration)); }
    public void setCurrentFraction(float value) { apply(Math.max(0, Math.min(1, value))); }

    public Object getAnimatedValue() {
        float t = interpolator == null ? fraction : interpolator.getInterpolation(fraction);
        if (floats != null && floats.length > 0) return floats.length == 1 ? floats[0] : between(floats, t);
        if (ints != null && ints.length > 0) {
            if (ints.length == 1) return ints[0];
            float scaled = t * (ints.length - 1); int i = Math.min(ints.length - 2, (int) scaled); float f = scaled - i;
            if (argb) return mixColor(ints[i], ints[i + 1], f);
            return Math.round(ints[i] + (ints[i + 1] - ints[i]) * f);
        }
        if (objects != null && objects.length > 0) {
            if (objects.length == 1 || evaluator == null) return t >= 1 ? objects[objects.length - 1] : objects[0];
            float scaled = t * (objects.length - 1); int i = Math.min(objects.length - 2, (int) scaled);
            @SuppressWarnings("unchecked") TypeEvaluator<Object> e = (TypeEvaluator<Object>) evaluator;
            return e.evaluate(scaled - i, objects[i], objects[i + 1]);
        }
        return null;
    }
    private static float between(float[] values, float t) {
        float scaled = t * (values.length - 1); int i = Math.min(values.length - 2, (int) scaled);
        return values[i] + (values[i + 1] - values[i]) * (scaled - i);
    }
    private static int mixColor(int from, int to, float f) {
        int mixed = 0;
        for (int shift = 0; shift <= 24; shift += 8) { int a = (from >>> shift) & 255, b = (to >>> shift) & 255; mixed |= Math.round(a + (b - a) * f) << shift; }
        return mixed;
    }

    /** Sets the animated value at `value` (0 start, 1 end) and tells the update listeners. */
    void apply(float value) {
        fraction = value;
        if (updates != null) for (var listener : new ArrayList<>(updates)) listener.onAnimationUpdate(this);
    }

    @Override public void start() {
        if (running) return;
        running = true; started = true;
        if (listeners != null) for (var l : new ArrayList<>(listeners)) l.onAnimationStart(this, false);
        boolean endless = repeatCount == INFINITE;
        apply(endless ? 0 : repeatMode == REVERSE && repeatCount % 2 == 1 ? 0 : 1);
        if (endless) return;
        pendingEnd = this::finish;
        MAIN.postDelayed(pendingEnd, Math.min(1000, startDelay + duration * (repeatCount + 1L)));
    }
    private void finish() {
        if (!running) return;
        running = false; started = false;
        if (pendingEnd != null) { MAIN.removeCallbacks(pendingEnd); pendingEnd = null; }
        if (listeners != null) for (var l : new ArrayList<>(listeners)) l.onAnimationEnd(this, false);
    }
    @Override public void cancel() {
        if (!running) return;
        if (listeners != null) for (var l : new ArrayList<>(listeners)) l.onAnimationCancel(this);
        finish();
    }
    @Override public void end() {
        if (!running) { start(); if (repeatCount == INFINITE) { running = false; return; } }
        apply(1);
        finish();
    }
    public void reverse() { apply(0); }
    @Override public boolean isRunning() { return running; }
    @Override public boolean isStarted() { return started; }
    @Override public ValueAnimator clone() { ValueAnimator copy = (ValueAnimator) super.clone(); if (updates != null) copy.updates = new ArrayList<>(updates); copy.running = false; copy.started = false; copy.pendingEnd = null; return copy; }
}
