package android.graphics.drawable;

import android.graphics.Canvas;

public class LayerDrawable extends Drawable {
    private Drawable[] layers;
    public LayerDrawable(Drawable[] layers) { this.layers = layers == null ? new Drawable[0] : layers.clone(); }
    public int getNumberOfLayers() { return layers.length; }
    public Drawable getDrawable(int index) { return layers[index]; }
    public void setLayerInset(int index, int l, int t, int r, int b) { }
    public boolean setDrawableByLayerId(int id, Drawable drawable) { return false; }
    public Drawable findDrawableByLayerId(int id) { return null; }
    public void setId(int index, int id) { }
    @Override public void draw(Canvas canvas) { for (Drawable layer : layers) if (layer != null) layer.draw(canvas); }
    @Override public Integer tvboxColor(int[] viewState) {
        Integer top = null;
        for (Drawable layer : layers) { Integer color = layer == null ? null : layer.tvboxColor(viewState); if (color != null && (color >>> 24) != 0) top = color; }
        return top;
    }
}
