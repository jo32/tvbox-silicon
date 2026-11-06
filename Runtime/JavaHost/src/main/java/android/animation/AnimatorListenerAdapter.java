package android.animation;

public abstract class AnimatorListenerAdapter implements Animator.AnimatorListener {
    @Override public void onAnimationCancel(Animator animation) { }
    @Override public void onAnimationEnd(Animator animation) { }
    @Override public void onAnimationRepeat(Animator animation) { }
    @Override public void onAnimationStart(Animator animation) { }
    public void onAnimationPause(Animator animation) { }
    public void onAnimationResume(Animator animation) { }
}
