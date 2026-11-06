package android.app;

import android.content.Context;
import org.json.JSONException;
import org.json.JSONObject;

public class ProgressDialog extends AlertDialog {
    public static final int STYLE_SPINNER = 0, STYLE_HORIZONTAL = 1;
    private int style = STYLE_SPINNER, max = 100, progress;
    private boolean indeterminate = true;
    private CharSequence text;

    public ProgressDialog(Context context) { super(context); }
    public ProgressDialog(Context context, int theme) { super(context, theme); }
    public static ProgressDialog show(Context context, CharSequence title, CharSequence message) { return show(context, title, message, false, false, null); }
    public static ProgressDialog show(Context context, CharSequence title, CharSequence message, boolean indeterminate) { return show(context, title, message, indeterminate, false, null); }
    public static ProgressDialog show(Context context, CharSequence title, CharSequence message, boolean indeterminate, boolean cancelable) { return show(context, title, message, indeterminate, cancelable, null); }
    public static ProgressDialog show(Context context, CharSequence title, CharSequence message, boolean indeterminate, boolean cancelable, OnCancelListener listener) {
        ProgressDialog dialog = new ProgressDialog(context);
        dialog.setTitle(title);
        dialog.setMessage(message);
        dialog.setIndeterminate(indeterminate);
        dialog.setCancelable(cancelable);
        dialog.setOnCancelListener(listener);
        dialog.show();
        return dialog;
    }
    @Override public void setMessage(CharSequence value) { text = value; super.setMessage(value); }
    public void setProgressStyle(int value) { style = value; if (value == STYLE_HORIZONTAL) indeterminate = false; }
    public void setMax(int value) { max = value; }
    public int getMax() { return max; }
    public void setProgress(int value) { progress = value; }
    public int getProgress() { return progress; }
    public void incrementProgressBy(int diff) { progress += diff; }
    public void setIndeterminate(boolean value) { indeterminate = value; }
    public boolean isIndeterminate() { return indeterminate; }
    public void setSecondaryProgress(int value) { }
    public void setProgressNumberFormat(String format) { }
    public void setProgressPercentFormat(java.text.NumberFormat format) { }
    public void setProgressDrawable(android.graphics.drawable.Drawable d) { }
    public void setIndeterminateDrawable(android.graphics.drawable.Drawable d) { }
    @Override public JSONObject tvboxDescribe() throws JSONException {
        JSONObject described = super.tvboxDescribe();
        JSONObject bar = new JSONObject().put("id", tvboxWindowID * -1).put("type", "progress").put("min", 0).put("max", max).put("progress", progress);
        if (indeterminate || style == STYLE_SPINNER) bar.put("indeterminate", true);
        return described.put("progress", bar);
    }
}
