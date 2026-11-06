package android.widget;

import android.content.Context;

public class SeekBar extends AbsSeekBar {
    public interface OnSeekBarChangeListener {
        void onProgressChanged(SeekBar bar, int progress, boolean fromUser);
        void onStartTrackingTouch(SeekBar bar);
        void onStopTrackingTouch(SeekBar bar);
    }
    private OnSeekBarChangeListener listener;
    public SeekBar(Context context) { super(context); }
    public SeekBar(Context context, android.util.AttributeSet attrs) { super(context); }
    public SeekBar(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public void setOnSeekBarChangeListener(OnSeekBarChangeListener value) { listener = value; }
    @Override void onProgressRefresh(boolean fromUser) { if (listener != null) listener.onProgressChanged(this, getProgress(), fromUser); }
    @Override public void tvboxSetValue(Object value) {
        if (!(value instanceof Number number)) return;
        if (listener != null) listener.onStartTrackingTouch(this);
        tvboxProgress(number.intValue(), true);
        if (listener != null) listener.onStopTrackingTouch(this);
    }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        super.tvboxDescribe(node);
        node.put("type", "slider").put("step", getKeyProgressIncrement());
    }
}
