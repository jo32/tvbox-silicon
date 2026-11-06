package android.graphics.drawable;

import android.graphics.Canvas;

public class GradientDrawable extends Drawable {
    public static final int RECTANGLE = 0, OVAL = 1, LINE = 2, RING = 3, LINEAR_GRADIENT = 0, RADIAL_GRADIENT = 1, SWEEP_GRADIENT = 2;
    public enum Orientation { TOP_BOTTOM, TR_BL, RIGHT_LEFT, BR_TL, BOTTOM_TOP, BL_TR, LEFT_RIGHT, TL_BR }
    private int[] colors;
    private android.content.res.ColorStateList colorList;
    private int shape, strokeWidth, strokeColor, gradientType, width = -1, height = -1;
    private float radius;
    private float[] radii;
    private Orientation orientation = Orientation.TOP_BOTTOM;

    public GradientDrawable() { }
    public GradientDrawable(Orientation orientation, int[] colors) { this.orientation = orientation; this.colors = colors; }
    public void setColor(int color) { colors = new int[]{color}; colorList = null; }
    public void setColor(android.content.res.ColorStateList value) { colorList = value; colors = null; }
    public void setColors(int[] value) { colors = value; colorList = null; }
    public int[] getColors() { return colors; }
    public void setShape(int value) { shape = value; }
    public int getShape() { return shape; }
    public void setCornerRadius(float value) { radius = value; radii = null; }
    public float getCornerRadius() { return radius; }
    public void setCornerRadii(float[] value) { radii = value; }
    public void setStroke(int width, int color) { strokeWidth = width; strokeColor = color; }
    public void setStroke(int width, int color, float dashWidth, float dashGap) { setStroke(width, color); }
    public void setStroke(int width, android.content.res.ColorStateList color) { setStroke(width, color == null ? 0 : color.getDefaultColor()); }
    public void setGradientType(int value) { gradientType = value; }
    public void setOrientation(Orientation value) { orientation = value; }
    public Orientation getOrientation() { return orientation; }
    public void setGradientRadius(float value) { }
    public void setGradientCenter(float x, float y) { }
    public void setUseLevel(boolean value) { }
    public void setDither(boolean value) { }
    public void setSize(int w, int h) { width = w; height = h; }
    @Override public int getIntrinsicWidth() { return width; }
    @Override public int getIntrinsicHeight() { return height; }
    @Override public void draw(Canvas canvas) { Integer color = tvboxColor(getState()); if (color != null) canvas.drawColor(color); }
    @Override public Drawable mutate() { return this; }
    @Override public Integer tvboxColor(int[] viewState) {
        if (colorList != null) return colorList.getColorForState(viewState, colorList.getDefaultColor());
        if (colors != null && colors.length > 0) return colors[0];
        return strokeWidth > 0 ? strokeColor & 0x00FFFFFF : null;
    }
    public float tvboxRadius() { return radii != null && radii.length > 0 ? radii[0] : radius; }
    public int tvboxStrokeColor() { return strokeWidth > 0 ? strokeColor : 0; }
    @Override protected Object clone() throws CloneNotSupportedException {
        GradientDrawable copy = (GradientDrawable) super.clone();
        if (colors != null) copy.colors = colors.clone();
        if (radii != null) copy.radii = radii.clone();
        return copy;
    }
}
