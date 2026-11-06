package android.animation;

import java.util.ArrayList;

/**
 * An animation. Nothing moves on screen here: the app draws each window as it is when asked, so animators
 * set their end values at once and tell their listeners on the plugin's main looper when the time is up.
 */
public abstract class Animator implements Cloneable {
    public static final long DURATION_INFINITE = -1;
    public interface AnimatorListener {
        default void onAnimationStart(Animator animation, boolean isReverse) { onAnimationStart(animation); }
        void onAnimationStart(Animator animation);
        default void onAnimationEnd(Animator animation, boolean isReverse) { onAnimationEnd(animation); }
        void onAnimationEnd(Animator animation);
        void onAnimationCancel(Animator animation);
        void onAnimationRepeat(Animator animation);
    }
    public interface AnimatorPauseListener { void onAnimationPause(Animator animation); void onAnimationResume(Animator animation); }

    ArrayList<AnimatorListener> listeners;
    private ArrayList<AnimatorPauseListener> pauseListeners;
    private boolean paused;

    public void addListener(AnimatorListener listener) { if (listeners == null) listeners = new ArrayList<>(); listeners.add(listener); }
    public void removeListener(AnimatorListener listener) { if (listeners != null) listeners.remove(listener); }
    public ArrayList<AnimatorListener> getListeners() { return listeners; }
    public void removeAllListeners() { listeners = null; pauseListeners = null; }
    public void addPauseListener(AnimatorPauseListener listener) { if (pauseListeners == null) pauseListeners = new ArrayList<>(); pauseListeners.add(listener); }
    public void removePauseListener(AnimatorPauseListener listener) { if (pauseListeners != null) pauseListeners.remove(listener); }
    public void start() { }
    public void cancel() { }
    public void end() { }
    public void pause() { if (isStarted() && !paused) { paused = true; if (pauseListeners != null) for (var l : new ArrayList<>(pauseListeners)) l.onAnimationPause(this); } }
    public void resume() { if (paused) { paused = false; if (pauseListeners != null) for (var l : new ArrayList<>(pauseListeners)) l.onAnimationResume(this); } }
    public boolean isPaused() { return paused; }
    public abstract long getStartDelay();
    public abstract void setStartDelay(long startDelay);
    public abstract Animator setDuration(long duration);
    public abstract long getDuration();
    public long getTotalDuration() { long d = getDuration(); return d < 0 ? DURATION_INFINITE : getStartDelay() + d; }
    public abstract void setInterpolator(TimeInterpolator value);
    public TimeInterpolator getInterpolator() { return null; }
    public abstract boolean isRunning();
    public boolean isStarted() { return isRunning(); }
    public void setTarget(Object target) { }
    public void setupStartValues() { }
    public void setupEndValues() { }
    @Override public Animator clone() {
        try {
            Animator copy = (Animator) super.clone();
            if (listeners != null) copy.listeners = new ArrayList<>(listeners);
            if (pauseListeners != null) copy.pauseListeners = new ArrayList<>(pauseListeners);
            return copy;
        } catch (CloneNotSupportedException impossible) { throw new AssertionError(impossible); }
    }
}
