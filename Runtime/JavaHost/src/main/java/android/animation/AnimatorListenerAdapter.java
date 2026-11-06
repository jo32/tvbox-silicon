package android.animation;

public abstract class AnimatorListenerAdapter implements Animator.AnimatorListener, Animator.AnimatorPauseListener {
    @Override public void onAnimationCancel(Animator animation) { }
    @Override public void onAnimationEnd(Animator animation) { }
    @Override public void onAnimationRepeat(Animator animation) { }
    @Override public void onAnimationStart(Animator animation) { }
    @Override public void onAnimationPause(Animator animation) { }
    @Override public void onAnimationResume(Animator animation) { }
}
