package android.app;

import android.content.ComponentName;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;

/** TVBox's current Activity: plugins open their settings dialogs and pages on it. */
public class Activity extends ContextWrapper {
    private Window window;

    public Activity(Context base) { super(base); }

    public Window getWindow() {
        if (window == null) window = new Window(this);
        return window;
    }
    public WindowManager getWindowManager() { return WindowManager.DEFAULT; }
    public void runOnUiThread(Runnable action) {
        if (Looper.getMainLooper().isCurrentThread()) action.run();
        else new Handler(Looper.getMainLooper()).post(action);
    }
    @Override public void startActivity(Intent intent) { tvbox.runtime.PluginWindows.open(intent); }
    public void startActivity(Intent intent, android.os.Bundle options) { startActivity(intent); }
    public void startActivityForResult(Intent intent, int requestCode) { startActivity(intent); }
    public Application getApplication() { return ActivityThread.currentApplication(); }
    public ComponentName getComponentName() { return new ComponentName(getPackageName(), getPackageName() + ".ui.activity.HomeActivity"); }
    public Intent getIntent() { return new Intent(); }
    public boolean isFinishing() { return false; }
    public boolean isDestroyed() { return false; }
    public void finish() { }
    public View findViewById(int id) { return null; }
    public View getCurrentFocus() { return null; }
    public void setContentView(View view) { }
    public void setContentView(int layout) { }
    public void requestPermissions(String[] permissions, int requestCode) { }
    public boolean shouldShowRequestPermissionRationale(String permission) { return false; }
    public void setRequestedOrientation(int orientation) { }
    public int getRequestedOrientation() { return -1; }
    public boolean hasWindowFocus() { return true; }
    public void overridePendingTransition(int enter, int exit) { }
}
