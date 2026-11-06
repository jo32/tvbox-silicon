package android.graphics.drawable;

import android.graphics.Bitmap;
import android.graphics.Canvas;

public class BitmapDrawable extends Drawable {
    private Bitmap bitmap;
    public BitmapDrawable() { }
    public BitmapDrawable(Bitmap bitmap) { this.bitmap = bitmap; }
    public BitmapDrawable(android.content.res.Resources resources, Bitmap bitmap) { this.bitmap = bitmap; }
    public final Bitmap getBitmap() { return bitmap; }
    public void setAntiAlias(boolean value) { }
    public void setFilterBitmap(boolean value) { }
    public void setGravity(int value) { }
    @Override public int getIntrinsicWidth() { return bitmap == null ? -1 : bitmap.getWidth(); }
    @Override public int getIntrinsicHeight() { return bitmap == null ? -1 : bitmap.getHeight(); }
    @Override public void draw(Canvas canvas) { }
}
