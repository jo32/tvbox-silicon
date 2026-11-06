package android.app;

import android.content.Context;
import android.content.DialogInterface;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ListAdapter;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class AlertDialog extends Dialog {
    public static final int THEME_DEVICE_DEFAULT_DARK = 4, THEME_DEVICE_DEFAULT_LIGHT = 5;
    private CharSequence message;
    private View view, customTitle;
    private CharSequence[] items;
    private ListAdapter adapter;
    private boolean[] checkedItems;
    private int checkedItem = -1;
    private int choiceMode; // 0 plain, 1 single, 2 multi
    private OnClickListener itemListener;
    private OnMultiChoiceClickListener multiListener;
    private final CharSequence[] buttonText = new CharSequence[3];
    private final OnClickListener[] buttonListeners = new OnClickListener[3];
    private final Button[] buttons = new Button[3];

    protected AlertDialog(Context context) { super(context); }
    protected AlertDialog(Context context, int themeResId) { super(context, themeResId); }
    protected AlertDialog(Context context, boolean cancelable, OnCancelListener cancelListener) { super(context, cancelable, cancelListener); }

    private static int slot(int which) { return switch (which) { case BUTTON_POSITIVE -> 0; case BUTTON_NEGATIVE -> 1; case BUTTON_NEUTRAL -> 2; default -> -1; }; }
    private static final int[] WHICH = {BUTTON_POSITIVE, BUTTON_NEGATIVE, BUTTON_NEUTRAL};
    private static final String[] ROLE = {"positive", "negative", "neutral"};

    public void setMessage(CharSequence value) { message = value; }
    public void setView(View value) { view = value; }
    public void setView(View value, int l, int t, int r, int b) { view = value; }
    public void setCustomTitle(View value) { customTitle = value; }
    public void setIcon(int resid) { }
    public void setIcon(android.graphics.drawable.Drawable icon) { }
    public void setButton(int which, CharSequence text, OnClickListener listener) {
        int i = slot(which);
        if (i < 0) return;
        buttonText[i] = text;
        buttonListeners[i] = listener;
        if (buttons[i] != null) buttons[i].setText(text);
    }
    public void setButton(int which, CharSequence text, android.os.Message message) { setButton(which, text, (OnClickListener) null); }
    public Button getButton(int which) { int i = slot(which); return i < 0 ? null : buttons[i]; }

    @Override protected void onCreate(android.os.Bundle savedInstanceState) {
        for (int i = 0; i < 3; i++) {
            if (buttonText[i] == null || buttonText[i].length() == 0) continue;
            Button button = new Button(getContext());
            button.setText(buttonText[i]);
            final int which = WHICH[i], index = i;
            button.setOnClickListener(v -> {
                if (buttonListeners[index] != null) buttonListeners[index].onClick(this, which);
                dismiss();
            });
            buttons[i] = button;
        }
        if (view != null && getWindow().tvboxContent() == null) setContentView(view);
    }

    private android.widget.ListView listView;
    /**
     * The dialog's list, which plugins read the checked row from (getCheckedItemPosition) when a button is
     * tapped; null when the dialog has no list, as on Android.
     */
    public android.widget.ListView getListView() {
        if (adapter == null && items == null) return null;
        if (listView == null) listView = new android.widget.ListView(getContext()) {
            @Override public int getCheckedItemPosition() { return choiceMode == 1 ? checkedItem : INVALID_POSITION; }
            @Override public boolean isItemChecked(int position) {
                return choiceMode == 1 ? position == checkedItem : choiceMode == 2 && checkedItems != null && position >= 0 && position < checkedItems.length && checkedItems[position];
            }
            @Override public void setItemChecked(int position, boolean value) {
                if (choiceMode == 1) { if (value) checkedItem = position; else if (checkedItem == position) checkedItem = -1; }
                else if (choiceMode == 2 && checkedItems != null && position >= 0 && position < checkedItems.length) checkedItems[position] = value;
            }
            @Override public int getCheckedItemCount() {
                if (choiceMode == 1) return checkedItem >= 0 ? 1 : 0;
                int n = 0; if (choiceMode == 2 && checkedItems != null) for (boolean on : checkedItems) if (on) n++; return n;
            }
            @Override public int getCount() { return adapter != null ? adapter.getCount() : items == null ? 0 : items.length; }
            @Override public Object getItemAtPosition(int position) {
                if (adapter != null) return position >= 0 && position < adapter.getCount() ? adapter.getItem(position) : null;
                return items != null && position >= 0 && position < items.length ? items[position] : null;
            }
            @Override public android.widget.ListAdapter getAdapter() { return adapter; }
            @Override public void setSelection(int position) { }
        };
        return listView;
    }

    /** The viewer picked list row `index`, as Android's list does. */
    public void tvboxItem(int index) {
        int count = adapter != null ? adapter.getCount() : items == null ? 0 : items.length;
        if (index < 0 || index >= count) return;
        switch (choiceMode) {
            case 1 -> { checkedItem = index; if (itemListener != null) itemListener.onClick(this, index); }
            case 2 -> {
                checkedItems[index] = !checkedItems[index];
                if (multiListener != null) multiListener.onClick(this, index, checkedItems[index]);
            }
            default -> { if (itemListener != null) itemListener.onClick(this, index); dismiss(); }
        }
    }

    @Override public View tvboxFind(int nodeID) {
        for (Button button : buttons) if (button != null && button.tvboxNodeID == nodeID) return button;
        View found = super.tvboxFind(nodeID);
        return found != null || customTitle == null ? found : customTitle.tvboxFind(nodeID);
    }

    @Override public JSONObject tvboxDescribe() throws JSONException {
        JSONObject described = super.tvboxDescribe();
        if (message != null && message.length() > 0) described.put("message", message.toString());
        if (customTitle != null) { JSONObject node = customTitle.tvboxNode(); if (node != null) described.put("header", node); }
        int count = adapter != null ? adapter.getCount() : items == null ? 0 : items.length;
        if (count > 0) {
            JSONArray rows = new JSONArray();
            ViewGroup holder = new android.widget.FrameLayout(getContext());
            for (int i = 0; i < count; i++) {
                String text;
                if (adapter != null) {
                    View row = adapter.getView(i, null, holder);
                    text = row == null ? String.valueOf(adapter.getItem(i)) : tvbox.runtime.PluginWindows.textOf(row);
                } else text = String.valueOf(items[i]);
                JSONObject entry = new JSONObject().put("text", text);
                if (choiceMode == 1) entry.put("checked", i == checkedItem);
                if (choiceMode == 2) entry.put("checked", checkedItems[i]);
                rows.put(entry);
            }
            described.put("items", rows).put("choice", choiceMode == 1 ? "single" : choiceMode == 2 ? "multi" : "plain");
        }
        JSONArray list = new JSONArray();
        for (int i = 0; i < 3; i++) {
            Button button = buttons[i];
            if (button == null || button.getVisibility() != View.VISIBLE) continue;
            JSONObject entry = new JSONObject().put("id", button.tvboxNodeID).put("text", String.valueOf(button.getText())).put("role", ROLE[i]);
            if (!button.isEnabled()) entry.put("enabled", false);
            list.put(entry);
        }
        if (list.length() > 0) described.put("buttons", list);
        return described;
    }

    public static class Builder {
        private final Context context;
        private CharSequence title, message;
        private View view, customTitle;
        private CharSequence[] items;
        private ListAdapter adapter;
        private boolean[] checkedItems;
        private int checkedItem = -1, choiceMode;
        private OnClickListener itemListener;
        private OnMultiChoiceClickListener multiListener;
        private final CharSequence[] buttonText = new CharSequence[3];
        private final OnClickListener[] buttonListeners = new OnClickListener[3];
        private boolean cancelable = true;
        private OnCancelListener cancelListener;
        private OnDismissListener dismissListener;
        private OnKeyListener keyListener;

        public Builder(Context context) { this.context = context; }
        public Builder(Context context, int themeResId) { this.context = context; }
        public Context getContext() { return context; }
        private CharSequence string(int resid) { return context.getResources().getString(resid); }
        public Builder setTitle(CharSequence value) { title = value; return this; }
        public Builder setTitle(int resid) { title = string(resid); return this; }
        public Builder setCustomTitle(View value) { customTitle = value; return this; }
        public Builder setMessage(CharSequence value) { message = value; return this; }
        public Builder setMessage(int resid) { message = string(resid); return this; }
        public Builder setIcon(int resid) { return this; }
        public Builder setIcon(android.graphics.drawable.Drawable icon) { return this; }
        public Builder setView(View value) { view = value; return this; }
        public Builder setView(int layoutResId) { return this; }
        public Builder setPositiveButton(CharSequence text, OnClickListener listener) { buttonText[0] = text; buttonListeners[0] = listener; return this; }
        public Builder setPositiveButton(int resid, OnClickListener listener) { return setPositiveButton(string(resid), listener); }
        public Builder setNegativeButton(CharSequence text, OnClickListener listener) { buttonText[1] = text; buttonListeners[1] = listener; return this; }
        public Builder setNegativeButton(int resid, OnClickListener listener) { return setNegativeButton(string(resid), listener); }
        public Builder setNeutralButton(CharSequence text, OnClickListener listener) { buttonText[2] = text; buttonListeners[2] = listener; return this; }
        public Builder setNeutralButton(int resid, OnClickListener listener) { return setNeutralButton(string(resid), listener); }
        public Builder setCancelable(boolean value) { cancelable = value; return this; }
        public Builder setOnCancelListener(OnCancelListener listener) { cancelListener = listener; return this; }
        public Builder setOnDismissListener(OnDismissListener listener) { dismissListener = listener; return this; }
        public Builder setOnKeyListener(OnKeyListener listener) { keyListener = listener; return this; }
        public Builder setItems(CharSequence[] values, OnClickListener listener) { items = values; adapter = null; itemListener = listener; choiceMode = 0; return this; }
        public Builder setItems(int resid, OnClickListener listener) { return this; }
        public Builder setAdapter(ListAdapter value, OnClickListener listener) { adapter = value; items = null; itemListener = listener; choiceMode = 0; return this; }
        public Builder setSingleChoiceItems(CharSequence[] values, int checked, OnClickListener listener) {
            items = values; adapter = null; checkedItem = checked; itemListener = listener; choiceMode = 1; return this;
        }
        public Builder setSingleChoiceItems(ListAdapter value, int checked, OnClickListener listener) {
            adapter = value; items = null; checkedItem = checked; itemListener = listener; choiceMode = 1; return this;
        }
        public Builder setMultiChoiceItems(CharSequence[] values, boolean[] checked, OnMultiChoiceClickListener listener) {
            items = values; adapter = null; checkedItems = checked != null ? checked : new boolean[values.length]; multiListener = listener; choiceMode = 2; return this;
        }
        public AlertDialog create() {
            AlertDialog dialog = new AlertDialog(context);
            dialog.setTitle(title);
            dialog.message = message;
            dialog.view = view;
            dialog.customTitle = customTitle;
            dialog.items = items;
            dialog.adapter = adapter;
            dialog.checkedItem = checkedItem;
            dialog.checkedItems = checkedItems;
            dialog.choiceMode = choiceMode;
            dialog.itemListener = itemListener;
            dialog.multiListener = multiListener;
            for (int i = 0; i < 3; i++) { dialog.buttonText[i] = buttonText[i]; dialog.buttonListeners[i] = buttonListeners[i]; }
            dialog.setCancelable(cancelable);
            dialog.setOnCancelListener(cancelListener);
            dialog.setOnDismissListener(dismissListener);
            dialog.setOnKeyListener(keyListener);
            return dialog;
        }
        public AlertDialog show() { AlertDialog dialog = create(); dialog.show(); return dialog; }
    }
}
