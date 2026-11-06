import android.app.*;
import android.graphics.Bitmap;
import android.widget.*;
import java.nio.file.Files;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.json.*;
import tvbox.runtime.*;

/** A plugin's own settings window: found as TVBox's Activity by reflection, described for the app, driven by its input. */
public class PluginWindowsTest {
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    public static void main(String[] args) throws Exception {
        com.github.catvod.spider.Init.application = new Application(Files.createTempDirectory("plugin-windows").toFile(), PluginWindowsTest.class.getClassLoader());
        PluginWindows.activity();
        // As aowu's AwInit.getActivity finds it.
        Class<?> type = Class.forName("android.app.ActivityThread");
        Object thread = type.getMethod("currentActivityThread").invoke(null);
        var records = type.getDeclaredField("mActivities"); records.setAccessible(true);
        Activity found = null;
        for (Object record : ((Map<?, ?>) records.get(thread)).values()) {
            var paused = record.getClass().getDeclaredField("paused"); paused.setAccessible(true);
            if (paused.getBoolean(record)) continue;
            var activity = record.getClass().getDeclaredField("activity"); activity.setAccessible(true);
            found = (Activity) activity.get(record);
        }
        check(found != null, "No resumed Activity");
        Activity activity = found;

        AtomicReference<String> saved = new AtomicReference<>();
        AtomicBoolean dismissed = new AtomicBoolean();
        activity.runOnUiThread(() -> {
            LinearLayout box = new LinearLayout(activity);
            box.setOrientation(LinearLayout.VERTICAL);
            EditText cookie = new EditText(activity);
            cookie.setHint("Cookie");
            box.addView(cookie);
            TextView save = new TextView(activity);
            save.setText("保存");
            box.addView(save);
            ImageView code = new ImageView(activity);
            code.setImageBitmap(Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888));
            box.addView(code);
            AlertDialog dialog = new AlertDialog.Builder(activity).setTitle("配置").setView(box).setNegativeButton("取消", null)
                .setOnDismissListener(d -> dismissed.set(true)).create();
            save.setOnClickListener(v -> {
                saved.set(cookie.getText().toString());
                Toast.makeText(activity, "已保存", Toast.LENGTH_SHORT).show();
                dialog.dismiss();
            });
            dialog.show();
        });
        PluginWindows.await(2_000);

        JSONObject state = PluginWindows.state();
        JSONArray windows = state.getJSONArray("windows");
        check(windows.length() == 1, "Window not shown: " + state);
        JSONObject window = windows.getJSONObject(0);
        check("配置".equals(window.optString("title")), "Title lost: " + window);
        check(window.getJSONArray("buttons").getJSONObject(0).getString("role").equals("negative"), "Button role lost: " + window);
        JSONArray children = window.getJSONObject("root").getJSONArray("children");
        JSONObject field = children.getJSONObject(0), button = children.getJSONObject(1), picture = children.getJSONObject(2);
        check(field.getString("type").equals("input") && field.getString("hint").equals("Cookie"), "Field not described: " + field);
        check(button.optBoolean("tappable") && button.getString("text").equals("保存"), "Listener not offered as a tap: " + button);
        check(picture.getString("type").equals("image") && !picture.getString("image").isEmpty(), "Bitmap not sent: " + picture);

        PluginWindows.handle(new JSONObject().put("window", window.getInt("id")).put("kind", "click").put("view", button.getInt("id"))
            .put("values", new JSONObject().put(String.valueOf(field.getInt("id")), "SESSDATA=1")));
        check("SESSDATA=1".equals(saved.get()), "Typed text did not reach the listener: " + saved.get());
        check(dismissed.get() && PluginWindows.state().getJSONArray("windows").length() == 0, "Dismissed window still listed");
        check(PluginNotices.take().contains("已保存"), "Toast lost");

        // A page the plugin opens goes to the app.
        activity.startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://example.com/login")));
        check(PluginWindows.state().getJSONArray("links").getString(0).equals("https://example.com/login"), "Opened page lost");
        choicesAndTouches(activity);
        System.out.println("PluginWindowsTest passed");
        android.os.Looper.shutdown();
    }

    /** lytvs 夸克线程: a single-choice list read back through getListView; aowu 弹幕颜色: a wheel the viewer touches. */
    static void choicesAndTouches(Activity activity) throws Exception {
        float[] hsv = new float[3];
        android.graphics.Color.colorToHSV(0xFF00FF00, hsv);
        check(Math.round(hsv[0]) == 120 && hsv[1] == 1f && hsv[2] == 1f, "HSV wrong: " + java.util.Arrays.toString(hsv));
        check(android.graphics.Color.HSVToColor(hsv) == 0xFF00FF00, "HSV round trip lost");

        AtomicReference<AlertDialog> list = new AtomicReference<>();
        AtomicReference<float[]> touched = new AtomicReference<>();
        activity.runOnUiThread(() -> {
            AlertDialog dialog = new AlertDialog.Builder(activity).setTitle("线程").setSingleChoiceItems(new String[] {"4", "8", "16"}, 0, null)
                .setPositiveButton("确定", (d, which) -> ((android.content.ClipboardManager) activity.getSystemService("clipboard"))
                    .setPrimaryClip(android.content.ClipData.newPlainText("t", String.valueOf(((AlertDialog) d).getListView().getCheckedItemPosition()))))
                .create();
            dialog.show();
            list.set(dialog);
            android.view.View wheel = new android.view.View(activity) {
                @Override protected void onDraw(android.graphics.Canvas canvas) { canvas.drawColor(0xFFFF0000); }
                @Override public boolean onTouchEvent(android.view.MotionEvent event) {
                    if (event.getAction() == android.view.MotionEvent.ACTION_UP) touched.set(new float[] {event.getX() / getWidth(), event.getY() / getHeight()});
                    return true;
                }
            };
            wheel.setLayoutParams(new android.view.ViewGroup.LayoutParams(200, 200));
            new AlertDialog.Builder(activity).setView(wheel).show();
        });
        PluginWindows.await(2_000);
        JSONArray windows = PluginWindows.state().getJSONArray("windows");
        check(windows.length() == 2, "Windows not shown: " + windows);
        JSONObject choice = windows.getJSONObject(0), picker = windows.getJSONObject(1);
        check("single".equals(choice.optString("choice")), "Choice kind lost: " + choice);
        JSONObject canvas = picker.getJSONObject("root");
        check(canvas.optBoolean("touch") && canvas.getString("type").equals("image"), "Touchable drawing not offered: " + canvas);

        PluginWindows.handle(new JSONObject().put("window", picker.getInt("id")).put("kind", "touch").put("view", canvas.getInt("id")).put("x", 0.25).put("y", 0.75));
        float[] at = touched.get();
        check(at != null && Math.abs(at[0] - 0.25f) < 0.02f && Math.abs(at[1] - 0.75f) < 0.02f, "Touch lost: " + java.util.Arrays.toString(at));
        PluginWindows.handle(new JSONObject().put("window", picker.getInt("id")).put("kind", "close"));

        PluginWindows.handle(new JSONObject().put("window", choice.getInt("id")).put("kind", "item").put("index", 2));
        int positive = -1;
        JSONArray buttons = choice.getJSONArray("buttons");
        for (int i = 0; i < buttons.length(); i++) if ("positive".equals(buttons.getJSONObject(i).getString("role"))) positive = buttons.getJSONObject(i).getInt("id");
        PluginWindows.handle(new JSONObject().put("window", choice.getInt("id")).put("kind", "click").put("view", positive));
        check("2".equals(PluginWindows.state().optString("clipboard")), "Checked row or clipboard lost");
        PluginWindows.closeAll();
    }
}
