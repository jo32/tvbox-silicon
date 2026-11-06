package android.graphics.drawable;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Rect;

/** Backgrounds and images; the host only reads their colors (tvboxColor) and bitmaps. */
public abstract class Drawable implements Cloneable {
    private final Rect bounds = new Rect();
    private int[] state = new int[0];
    private int alpha = 255;

    public abstract static class ConstantState {
        public abstract Drawable newDrawable();
        public Drawable newDrawable(android.content.res.Resources resources) { return newDrawable(); }
        public int getChangingConfigurations() { return 0; }
    }

    public abstract void draw(Canvas canvas);
    public void setAlpha(int value) { alpha = value; }
    public int getAlpha() { return alpha; }
    public void setColorFilter(ColorFilter filter) { }
    public void setColorFilter(int color, android.graphics.PorterDuff.Mode mode) { }
    public void clearColorFilter() { }
    public void setTint(int color) { }
    public void setTintList(android.content.res.ColorStateList tint) { }
    public int getOpacity() { return -3; }
    public void setBounds(int left, int top, int right, int bottom) { bounds.set(left, top, right, bottom); }
    public void setBounds(Rect value) { bounds.set(value); }
    public final Rect getBounds() { return new Rect(bounds); }
    public int getIntrinsicWidth() { return -1; }
    public int getIntrinsicHeight() { return -1; }
    public int getMinimumWidth() { return Math.max(0, getIntrinsicWidth()); }
    public int getMinimumHeight() { return Math.max(0, getIntrinsicHeight()); }
    public Drawable mutate() { return this; }
    public boolean setState(int[] value) { state = value == null ? new int[0] : value.clone(); return true; }
    public int[] getState() { return state; }
    public boolean isStateful() { return false; }
    public Drawable getCurrent() { return this; }
    public boolean setVisible(boolean visible, boolean restart) { return true; }
    public void invalidateSelf() { }
    public void setCallback(Callback callback) { }
    public interface Callback {
        void invalidateDrawable(Drawable who);
        void scheduleDrawable(Drawable who, Runnable what, long when);
        void unscheduleDrawable(Drawable who, Runnable what);
    }
    public ConstantState getConstantState() {
        return new ConstantState() {
            @Override public Drawable newDrawable() {
                try { return (Drawable) Drawable.this.clone(); } catch (CloneNotSupportedException impossible) { return Drawable.this; }
            }
        };
    }
    /** The fill color for this view state, or null when it has none. */
    public Integer tvboxColor(int[] viewState) { return null; }
}
