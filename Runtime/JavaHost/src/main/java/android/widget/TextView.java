package android.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.text.TextPaint;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.View;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import org.json.JSONException;
import org.json.JSONObject;

public class TextView extends View {
    public enum BufferType { NORMAL, SPANNABLE, EDITABLE }
    public interface OnEditorActionListener { boolean onEditorAction(TextView view, int actionId, KeyEvent event); }

    CharSequence text = "";
    private CharSequence hint;
    private ColorStateList textColors = ColorStateList.valueOf(0xFF000000), hintColors;
    private final TextPaint paint = new TextPaint();
    private Typeface typeface = Typeface.DEFAULT;
    private int gravity = 0x800033, maxLines = Integer.MAX_VALUE, inputType = 1, imeOptions, imeAction;
    private boolean singleLine, allCaps;
    private TextUtils.TruncateAt ellipsize;
    private OnEditorActionListener editorListener;
    final List<TextWatcher> watchers = new CopyOnWriteArrayList<>();

    public TextView(Context context) { super(context); paint.setTextSize(28f); }
    public TextView(Context context, android.util.AttributeSet attrs) { this(context); }
    public TextView(Context context, android.util.AttributeSet attrs, int defStyleAttr) { this(context); }
    public TextView(Context context, android.util.AttributeSet attrs, int defStyleAttr, int defStyleRes) { this(context); }

    public CharSequence getText() { return text; }
    public void setText(CharSequence value) { replaceText(value == null ? "" : value); }
    public final void setText(CharSequence value, BufferType type) { setText(value); }
    public final void setText(int resid) { setText(getResources().getString(resid)); }
    public final void setText(char[] chars, int start, int length) { setText(new String(chars, start, length)); }
    public final void append(CharSequence more) { setText(String.valueOf(getText()) + more); }
    void replaceText(CharSequence value) {
        CharSequence before = text;
        if (watchers.isEmpty()) { text = value; return; }
        for (TextWatcher w : watchers) w.beforeTextChanged(before, 0, before.length(), value.length());
        text = value;
        for (TextWatcher w : watchers) w.onTextChanged(text, 0, before.length(), value.length());
        for (TextWatcher w : watchers) w.afterTextChanged(editable());
    }
    android.text.Editable editable() { return tvbox.runtime.EditableText.create(text); }
    public int length() { return text.length(); }
    public CharSequence getHint() { return hint; }
    public final void setHint(CharSequence value) { hint = value; }
    public final void setHint(int resid) { hint = getResources().getString(resid); }
    public void setTextColor(int color) { textColors = ColorStateList.valueOf(color); }
    public void setTextColor(ColorStateList colors) { if (colors != null) textColors = colors; }
    public final ColorStateList getTextColors() { return textColors; }
    public final int getCurrentTextColor() { return textColors.getColorForState(getDrawableState(), textColors.getDefaultColor()); }
    public final void setHintTextColor(int color) { hintColors = ColorStateList.valueOf(color); }
    public final void setHintTextColor(ColorStateList colors) { hintColors = colors; }
    public final void setLinkTextColor(int color) { }
    public void setHighlightColor(int color) { }
    public float getTextSize() { return paint.getTextSize(); }
    public void setTextSize(float sp) { setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, sp); }
    public void setTextSize(int unit, float size) { paint.setTextSize(android.util.TypedValue.applyDimension(unit, size, getResources().getDisplayMetrics())); }
    public TextPaint getPaint() { return paint; }
    public Typeface getTypeface() { return typeface; }
    public void setTypeface(Typeface value) { typeface = value == null ? Typeface.DEFAULT : value; }
    public void setTypeface(Typeface value, int style) { typeface = style == 0 && value != null ? value : Typeface.create(value, style); }
    public int getGravity() { return gravity; }
    public void setGravity(int value) { gravity = value; }
    public int getMaxLines() { return maxLines; }
    public void setMaxLines(int value) { maxLines = value; }
    public void setLines(int value) { maxLines = value; }
    public void setMinLines(int value) { }
    public void setSingleLine() { setSingleLine(true); }
    public void setSingleLine(boolean value) { singleLine = value; if (value) maxLines = 1; }
    public void setEllipsize(TextUtils.TruncateAt where) { ellipsize = where; }
    public TextUtils.TruncateAt getEllipsize() { return ellipsize; }
    public void setAllCaps(boolean value) { allCaps = value; }
    public void setMarqueeRepeatLimit(int value) { }
    public void setHorizontallyScrolling(boolean value) { }
    public void setMinHeight(int value) { setMinimumHeight(value); }
    public void setMinWidth(int value) { setMinimumWidth(value); }
    public void setMaxWidth(int value) { }
    public void setMaxHeight(int value) { }
    public void setWidth(int value) { }
    public void setHeight(int value) { }
    public void setEms(int value) { }
    public void setMaxEms(int value) { }
    public void setLineSpacing(float add, float mult) { }
    public void setLetterSpacing(float value) { }
    public void setShadowLayer(float radius, float dx, float dy, int color) { }
    public void setIncludeFontPadding(boolean value) { }
    public void setCursorVisible(boolean value) { }
    public void setTextIsSelectable(boolean value) { }
    public void setTextAlignment(int value) { }
    public void setAutoSizeTextTypeWithDefaults(int type) { }
    public void setCompoundDrawables(Drawable l, Drawable t, Drawable r, Drawable b) { }
    public void setCompoundDrawablesWithIntrinsicBounds(Drawable l, Drawable t, Drawable r, Drawable b) { }
    public void setCompoundDrawablesWithIntrinsicBounds(int l, int t, int r, int b) { }
    public void setCompoundDrawablesRelativeWithIntrinsicBounds(Drawable s, Drawable t, Drawable e, Drawable b) { }
    public void setCompoundDrawablePadding(int pad) { }
    public void setFilters(android.text.InputFilter[] filters) { }
    public void setMovementMethod(android.text.method.MovementMethod method) { }
    public void setTransformationMethod(android.text.method.TransformationMethod method) { }
    public void setKeyListener(android.text.method.KeyListener listener) { }
    public void setError(CharSequence error) { if (error != null) tvbox.runtime.PluginNotices.add(error); }
    public int getInputType() { return inputType; }
    public void setInputType(int value) { inputType = value; }
    public void setRawInputType(int value) { inputType = value; }
    public int getImeOptions() { return imeOptions; }
    public void setImeOptions(int value) { imeOptions = value; }
    public void setImeActionLabel(CharSequence label, int actionId) { imeAction = actionId; }
    public int getLineCount() { return 1; }
    public int getSelectionStart() { return text.length(); }
    public int getSelectionEnd() { return text.length(); }
    public boolean hasSelection() { return false; }
    public void setOnEditorActionListener(OnEditorActionListener listener) { editorListener = listener; }
    public void onEditorAction(int actionCode) { if (editorListener != null) editorListener.onEditorAction(this, actionCode, null); }
    public void addTextChangedListener(TextWatcher watcher) { if (watcher != null) watchers.add(watcher); }
    public void removeTextChangedListener(TextWatcher watcher) { watchers.remove(watcher); }
    @Override public void tvboxSubmit() {
        int action = imeAction != 0 ? imeAction : (imeOptions & 0xff) != 0 ? imeOptions & 0xff : 6;
        if (editorListener != null && editorListener.onEditorAction(this, action, null)) return;
        if (editorListener != null) editorListener.onEditorAction(this, 0, new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER));
    }
    boolean tvboxSubmits() { return editorListener != null; }

    @Override protected void tvboxDescribe(JSONObject node) throws JSONException {
        String shown = String.valueOf(getText());
        node.put("type", "text").put("text", allCaps ? shown.toUpperCase() : shown);
        if (hint != null && hint.length() > 0) node.put("hint", hint.toString());
        int color = getCurrentTextColor();
        node.put("color", tvbox.runtime.PluginWindows.hex(color));
        float scaled = getResources().getDisplayMetrics().scaledDensity;
        node.put("size", Math.round(getTextSize() / scaled * 10f) / 10f);
        if (typeface.isBold() || paint.isFakeBoldText()) node.put("bold", true);
        if (maxLines != Integer.MAX_VALUE) node.put("lines", maxLines);
        node.put("gravity", gravity);
    }
}
