package tvbox.runtime;

import android.app.Activity;
import android.app.ActivityThread;
import android.app.AlertDialog;
import android.app.Dialog;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * The windows a plugin shows. Plugins draw their settings (aowu's 配置中心, FTY's drive settings) with Android
 * dialogs and views on the Activity they find through ActivityThread, as in TVBox. This host keeps those views:
 * the app draws them from `state()` and sends the viewer's input back through `handle`, which runs the plugin's
 * own listeners on its main looper. Nothing here knows any plugin.
 */
public final class PluginWindows {
    private static final AtomicInteger IDS = new AtomicInteger();
    private static final List<Dialog> showing = new ArrayList<>();
    private static final List<String> links = new ArrayList<>();
    private PluginWindows() { }

    /** Identifies a window or a view in what the app is sent. */
    public static int nextID() { return IDS.incrementAndGet(); }
    public static synchronized void shown(Dialog dialog) { showing.remove(dialog); showing.add(dialog); }
    public static synchronized void dismissed(Dialog dialog) { showing.remove(dialog); }
    public static boolean any() { synchronized (PluginWindows.class) { if (!showing.isEmpty()) return true; } return overlays() != null; }
    public static synchronized boolean showing(Dialog dialog) { return showing.contains(dialog); }
    private static synchronized List<Dialog> windows() { return new ArrayList<>(showing); }

    /** A page the plugin opened (an ACTION_VIEW Intent with an address), for the app to open. */
    public static synchronized void open(Intent intent) {
        if (intent != null && intent.getChooserTarget() != null) intent = intent.getChooserTarget();
        String link = intent == null ? null : intent.getDataString();
        if (link == null && intent != null) link = intent.getStringExtra(Intent.EXTRA_TEXT);
        if (link != null) openLink(link);
    }
    /** A page for the app to open (a web view's address). */
    public static synchronized void openLink(String link) {
        if (link != null && link.matches("(?i)[a-z][a-z0-9+.-]*:.+")) links.add(link);
    }

    private static volatile boolean settingOpen;
    /**
     * While the viewer is on one of the plugin's settings, the plugin's own sign-in runs untouched: it shows
     * its QR code in its own window (HttpDiagnostics leaves its login requests alone).
     */
    public static void settingOpen(boolean open) { settingOpen = open; CloudDriveBridge.openToNetwork(open); }
    public static boolean settingOpen() { return settingOpen; }

    private static String clipboard;
    /** Text the plugin copied, for the app to put on the device's pasteboard. */
    public static synchronized void copied(String text) { clipboard = text; }

    /** The Activity plugins find as TVBox's current one; it exists once the plugin's Application does. */
    public static Activity activity() { return ActivityThread.currentActivityThread().hostActivity(); }

    /** Runs `work` on the plugin's main looper, where Android runs all UI code, and waits for it. */
    public static <T> T onMain(Callable<T> work) throws Exception {
        Looper main = Looper.getMainLooper();
        if (main.isCurrentThread()) return work.call();
        var result = new CompletableFuture<T>();
        boolean posted = new Handler(main).post(() -> {
            try { result.complete(work.call()); } catch (Throwable error) { result.completeExceptionally(error); }
        });
        if (!posted) throw new IllegalStateException("The plugin has closed");
        try { return result.get(15, TimeUnit.SECONDS); }
        catch (ExecutionException failed) {
            if (failed.getCause() instanceof Exception error) throw error;
            throw failed;
        }
    }

    /** Lets what the plugin has posted to its main looper so far run. */
    public static void settle() {
        try { onMain(() -> null); } catch (Exception closed) { }
    }

    /**
     * Waits up to `millis` for a window or a notice: an action often does its work on a background thread
     * (reading its settings, a request) and shows its dialog from there.
     */
    public static void await(long millis) throws InterruptedException {
        long end = System.currentTimeMillis() + millis;
        while (true) {
            settle();
            if (any() || PluginNotices.pending() || System.currentTimeMillis() >= end) return;
            Thread.sleep(100);
        }
    }

    /** {"windows": [...], "links": [...]}: the showing windows, topmost last, and pages to open. */
    public static JSONObject state() throws Exception {
        settle();
        JSONArray windows = onMain(() -> {
            JSONArray list = new JSONArray();
            View overlay = overlays();
            JSONObject overlayNode = overlay == null ? null : overlay.tvboxNode();
            if (overlayNode != null) list.put(new JSONObject().put("id", ACTIVITY_WINDOW).put("cancelable", true).put("root", overlayNode));
            for (Dialog dialog : windows()) {
                if (!dialog.isShowing()) continue;
                try { list.put(dialog.tvboxDescribe()); }
                catch (Exception failed) { System.err.println("PLUGIN_WINDOW_ERROR " + failed); }
            }
            return list;
        });
        JSONArray opened;
        String copied;
        synchronized (PluginWindows.class) { opened = new JSONArray(links); links.clear(); copied = clipboard; clipboard = null; }
        JSONObject state = new JSONObject().put("windows", windows).put("links", opened);
        return copied == null ? state : state.put("clipboard", copied);
    }

    /**
     * The viewer's input to a window, run as the tap or edit would run on Android: {"window": id,
     * "values": {"<view>": text | true | number}, "kind": "click" | "submit" | "item" | "change" | "back" | "close" | "poll",
     * "view": id, "index": n}. Values are applied first, so a button's listener reads what was typed.
     */
    public static void handle(JSONObject event) throws Exception {
        int id = event.optInt("window", -1);
        onMain(() -> {
            Dialog dialog = null;
            for (Dialog shown : windows()) if (shown.tvboxWindowID == id) dialog = shown;
            View overlay = id == ACTIVITY_WINDOW ? overlays() : null;
            if (dialog == null && overlay == null) return null; // closed meanwhile
            final Dialog window = dialog;
            java.util.function.IntFunction<View> find = node -> window != null ? window.tvboxFind(node) : overlay.tvboxFind(node);
            JSONObject values = event.optJSONObject("values");
            if (values != null) {
                for (Iterator<?> keys = values.keys(); keys.hasNext();) {
                    String key = String.valueOf(keys.next());
                    View view = find.apply(Integer.parseInt(key));
                    if (view != null) view.tvboxSetValue(values.get(key));
                }
            }
            switch (event.optString("kind")) {
                case "click" -> {
                    View view = find.apply(event.optInt("view", -1));
                    if (view != null && view.isEnabled()) view.tvboxActivate();
                }
                case "submit" -> {
                    View view = find.apply(event.optInt("view", -1));
                    if (view != null) view.tvboxSubmit();
                }
                case "item" -> { if (window instanceof AlertDialog alert) alert.tvboxItem(event.optInt("index", -1)); }
                case "touch" -> {
                    View view = find.apply(event.optInt("view", -1));
                    if (view != null && view.isEnabled()) view.tvboxTouch((float) event.optDouble("x", 0.5), (float) event.optDouble("y", 0.5));
                }
                case "back" -> {
                    if (window != null) window.tvboxBack();
                    else if (!overlayBack(overlay)) ((android.view.ViewGroup) overlay).removeAllViews();
                }
                case "close" -> {
                    if (window != null) window.tvboxClose();
                    else ((android.view.ViewGroup) overlay).removeAllViews();
                }
                default -> { }
            }
            return null;
        });
    }

    /**
     * Views a plugin added straight to the Activity's window (an overlay rather than a dialog),
     * shown as one more window under the dialogs; null when there are none.
     */
    static final int ACTIVITY_WINDOW = 0;
    private static View overlays() {
        Activity activity = ActivityThread.currentActivityThread().hostActivity();
        View decor = activity == null ? null : activity.getWindow().peekDecorView();
        return decor instanceof android.view.ViewGroup group && group.getChildCount() > 0 ? decor : null;
    }
    /** Back to an overlay goes to the views that listen for keys, as Android sends it to the focused one. */
    private static boolean overlayBack(View root) {
        Activity activity = ActivityThread.currentActivityThread().hostActivity();
        if (activity != null && activity.getWindow().tvboxBackCallback()) return true;
        View focused = root.findFocus();
        for (View target : new View[]{focused, root instanceof android.view.ViewGroup g && g.getChildCount() > 0 ? g.getChildAt(g.getChildCount() - 1) : null}) {
            if (target == null) continue;
            var down = new android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_BACK);
            var up = new android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_BACK);
            if (target.dispatchKeyEvent(down) | target.dispatchKeyEvent(up)) return true;
        }
        return false;
    }

    /** Closes every window, as when the viewer leaves the page or the plugin closes. */
    public static void closeAll() throws Exception {
        if (!any()) return;
        onMain(() -> {
            for (Dialog dialog : windows()) dialog.tvboxClose();
            if (overlays() instanceof android.view.ViewGroup group) group.removeAllViews();
            return null;
        });
    }

    /** #AARRGGBB, as the app reads colors. */
    public static String hex(int color) { return String.format("#%08X", color); }

    private static final java.util.Map<Bitmap, String> encoded = java.util.Collections.synchronizedMap(new java.util.WeakHashMap<>());
    /** A bitmap as base64 PNG; `keep` reuses the encoding of a bitmap the plugin no longer draws into. */
    public static String png(Bitmap bitmap, boolean keep) {
        if (keep) { String known = encoded.get(bitmap); if (known != null) return known; }
        var bytes = new java.io.ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        String text = java.util.Base64.getEncoder().encodeToString(bytes.toByteArray());
        if (keep) encoded.put(bitmap, text);
        return text;
    }

    /** The text a row view shows, for list rows the app draws as text. */
    public static String textOf(View view) {
        StringBuilder out = new StringBuilder();
        collectText(view, out);
        return out.toString().trim();
    }
    private static void collectText(View view, StringBuilder out) {
        if (view == null || view.getVisibility() != View.VISIBLE) return;
        if (view instanceof android.widget.TextView text) {
            CharSequence shown = text.getText();
            if (shown != null && shown.length() > 0) { if (out.length() > 0) out.append("  "); out.append(shown); }
        }
        if (view instanceof android.view.ViewGroup group) for (int i = 0; i < group.getChildCount(); i++) collectText(group.getChildAt(i), out);
    }

    /** Whether a plugin view class draws itself (overrides onDraw), so the app gets its picture. */
    public static boolean drawsItself(Class<?> type) { return overrides(type, "onDraw", android.graphics.Canvas.class); }
    /** Whether a plugin class (not the host's android classes) declares this method. */
    public static boolean overrides(Class<?> type, String name, Class<?>... parameters) {
        for (Class<?> c = type; c != null && !c.getName().startsWith("android."); c = c.getSuperclass()) {
            try { c.getDeclaredMethod(name, parameters); return true; } catch (NoSuchMethodException | NoClassDefFoundError none) { }
        }
        return false;
    }

    /** android.R.string values plugins pass for button titles. */
    public static String systemString(int id) {
        return switch (id) {
            case 17039370 -> "OK";
            case 17039360 -> "Cancel";
            case 17039379 -> "Yes";
            case 17039369 -> "No";
            case 17039380 -> "Copy";
            case 17039371 -> "Paste";
            default -> "";
        };
    }
}
