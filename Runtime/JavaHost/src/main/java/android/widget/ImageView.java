package android.widget;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.view.View;

public class ImageView extends View {
    public enum ScaleType { MATRIX, FIT_XY, FIT_START, FIT_CENTER, FIT_END, CENTER, CENTER_CROP, CENTER_INSIDE }
    private Drawable drawable;
    private ScaleType scaleType = ScaleType.FIT_CENTER;
    private boolean adjustViewBounds, cropToPadding;

    public ImageView(Context context) { super(context); }
    public ImageView(Context context, android.util.AttributeSet attrs) { super(context); }
    public ImageView(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }

    public Drawable getDrawable() { return drawable; }
    public void setImageDrawable(Drawable value) { drawable = value; }
    public void setImageBitmap(Bitmap bitmap) { drawable = bitmap == null ? null : new BitmapDrawable(getResources(), bitmap); }
    public void setImageResource(int resid) { if (resid == 0) drawable = null; }
    public void setImageURI(android.net.Uri uri) { }
    public ScaleType getScaleType() { return scaleType; }
    public void setScaleType(ScaleType value) { if (value != null) scaleType = value; }
    public boolean getAdjustViewBounds() { return adjustViewBounds; }
    public void setAdjustViewBounds(boolean value) { adjustViewBounds = value; }
    public boolean getCropToPadding() { return cropToPadding; }
    public void setCropToPadding(boolean value) { cropToPadding = value; }
    public void setMaxWidth(int value) { }
    public void setMaxHeight(int value) { }
    public void setColorFilter(int color) { }
    public void setColorFilter(int color, android.graphics.PorterDuff.Mode mode) { }
    public void setColorFilter(android.graphics.ColorFilter filter) { }
    public void clearColorFilter() { }
    public void setImageTintList(android.content.res.ColorStateList tint) { }
    public void setImageAlpha(int alpha) { }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        Bitmap bitmap = drawable instanceof BitmapDrawable bd ? bd.getBitmap() : null;
        if (bitmap == null) {
            Integer color = drawable == null ? null : drawable.tvboxColor(getDrawableState());
            if (color != null) node.put("background", tvbox.runtime.PluginWindows.hex(color));
            return;
        }
        node.put("type", "image").put("image", tvbox.runtime.PluginWindows.png(bitmap, true))
            .put("fill", scaleType == ScaleType.CENTER_CROP || scaleType == ScaleType.FIT_XY);
        if (!node.has("width") && !node.has("height")) {
            float density = getResources().getDisplayMetrics().density;
            node.put("width", Math.round(bitmap.getWidth() / density)).put("height", Math.round(bitmap.getHeight() / density));
        }
    }
}
