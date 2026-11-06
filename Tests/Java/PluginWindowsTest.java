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
        System.out.println("PluginWindowsTest passed");
        android.os.Looper.shutdown();
    }
}
