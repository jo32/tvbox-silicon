package android.graphics.drawable;

import android.graphics.Canvas;

public class ColorDrawable extends Drawable {
    private int color;
    public ColorDrawable() { }
    public ColorDrawable(int color) { this.color = color; }
    public int getColor() { return color; }
    public void setColor(int value) { color = value; }
    @Override public void draw(Canvas canvas) { canvas.drawColor(color); }
    @Override public Integer tvboxColor(int[] viewState) { return color; }
}
