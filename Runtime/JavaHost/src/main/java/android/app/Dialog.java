package android.app;

import android.content.Context;
import android.content.DialogInterface;
import android.view.KeyEvent;
import android.view.View;
import android.view.Window;
import org.json.JSONException;
import org.json.JSONObject;

/** A plugin's window; while it shows, the app draws it (tvbox.runtime.PluginWindows). */
public class Dialog implements DialogInterface {
    public final int tvboxWindowID = tvbox.runtime.PluginWindows.nextID();
    private final Context context;
    private final Window window;
    private boolean showing, created, cancelable = true;
    private CharSequence title;
    private Activity owner;
    private OnCancelListener cancelListener;
    private OnDismissListener dismissListener;
    private OnShowListener showListener;
    private OnKeyListener keyListener;

    public Dialog(Context context) { this(context, 0); }
    public Dialog(Context context, int themeResId) {
        this.context = context;
        window = new Window(context);
        if (context instanceof Activity activity) owner = activity;
    }
    protected Dialog(Context context, boolean cancelable, OnCancelListener cancelListener) {
        this(context, 0);
        this.cancelable = cancelable;
        this.cancelListener = cancelListener;
    }

    public final Context getContext() { return context; }
    public Window getWindow() { return window; }
    public final Activity getOwnerActivity() { return owner; }
    public final void setOwnerActivity(Activity activity) { owner = activity; }
    public void setContentView(View view) { window.setContentView(view); }
    public void setContentView(View view, android.view.ViewGroup.LayoutParams params) { window.setContentView(view, params); }
    public void setContentView(int layoutResID) { }
    public <T extends View> T findViewById(int id) { return window.getDecorView().findViewById(id); }
    public View getCurrentFocus() { return window.getDecorView().findFocus(); }
    public void setTitle(CharSequence value) { title = value; }
    public void setTitle(int resid) { title = context.getResources().getString(resid); }
    public CharSequence tvboxTitle() { return title; }
    public final boolean requestWindowFeature(int feature) { return true; }
    public boolean isShowing() { return showing; }
    public void setCancelable(boolean value) { cancelable = value; }
    public boolean tvboxCancelable() { return cancelable; }
    public void setCanceledOnTouchOutside(boolean cancel) { if (cancel) cancelable = true; }
    public void setOnCancelListener(OnCancelListener listener) { cancelListener = listener; }
    public void setOnDismissListener(OnDismissListener listener) { dismissListener = listener; }
    public void setOnShowListener(OnShowListener listener) { showListener = listener; }
    public void setOnKeyListener(OnKeyListener listener) { keyListener = listener; }
    public void setCancelMessage(android.os.Message message) { }
    public void setDismissMessage(android.os.Message message) { }

    protected void onCreate(android.os.Bundle savedInstanceState) { }
    protected void onStart() { }
    protected void onStop() { }
    public void onBackPressed() { if (cancelable) cancel(); }
    public boolean onKeyDown(int keyCode, KeyEvent event) { return false; }
    public boolean onKeyUp(int keyCode, KeyEvent event) { if (keyCode == KeyEvent.KEYCODE_BACK) { onBackPressed(); return true; } return false; }
    public void create() { if (!created) { created = true; onCreate(null); } }

    public void show() {
        if (showing) return;
        create();
        onStart();
        showing = true;
        tvbox.runtime.PluginWindows.shown(this);
        if (showListener != null) showListener.onShow(this);
        View decor = window.getDecorView();
        decor.post(decor::tvboxDispatchLayout);
    }
    public void hide() { if (showing) { showing = false; tvbox.runtime.PluginWindows.dismissed(this); } }
    @Override public void dismiss() {
        boolean was = showing || tvbox.runtime.PluginWindows.showing(this);
        showing = false;
        tvbox.runtime.PluginWindows.dismissed(this);
        if (!was) return;
        onStop();
        if (dismissListener != null) dismissListener.onDismiss(this);
    }
    @Override public void cancel() {
        if (showing && cancelListener != null) cancelListener.onCancel(this);
        dismiss();
    }

    /** Android's Back: the window's key listener, then cancel when the window allows it. */
    public void tvboxBack() {
        if (keyListener != null) {
            boolean handled = keyListener.onKey(this, KeyEvent.KEYCODE_BACK, new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK));
            handled |= keyListener.onKey(this, KeyEvent.KEYCODE_BACK, new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK));
            if (handled) return;
        }
        if (window.tvboxBackCallback()) return;
        if (!onKeyDown(KeyEvent.KEYCODE_BACK, new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK))) onBackPressed();
    }
    /** The viewer left the page: the window goes, as when its Activity goes. */
    public void tvboxClose() { cancel(); }
    public View tvboxFind(int nodeID) { return window.getDecorView().tvboxFind(nodeID); }
    public JSONObject tvboxDescribe() throws JSONException {
        JSONObject described = new JSONObject().put("id", tvboxWindowID).put("cancelable", cancelable);
        if (title != null && title.length() > 0) described.put("title", title.toString());
        View content = window.tvboxContent();
        JSONObject root = content == null ? null : content.tvboxNode();
        if (root != null) described.put("root", root);
        android.graphics.drawable.Drawable background = window.tvboxBackground();
        Integer fill = background == null ? null : background.tvboxColor(new int[0]);
        if (fill != null && (fill >>> 24) != 0) described.put("background", tvbox.runtime.PluginWindows.hex(fill));
        return described;
    }
}
