package tvbox.runtime;

import java.nio.file.Path;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * The Wex family (王二小's 玩偶, 花卷 and other AiNew drive lines) signs in to drives only in its own
 * config center, which also answers as JSON on the plugin's proxy:
 * {@code ?do=pan&action=loginStart&provider=…} gives a QR address and a task, {@code loginPoll} reports
 * {@code waiting}, {@code success}, {@code expired} or {@code error}, and the plugin saves the account
 * itself. When a line answers that its drive has no sign-in ("[pan115](resolvePlay) 115 Cookie
 * 未配置或已失效"), the host starts that sign-in, the app shows the code (LoginPrompt), and once it is
 * confirmed the line is asked again. Drives the app signs in to itself (Quark, UC, Baidu) reach the
 * plugin from the app's accounts (CloudDriveBridge.seedWexCookies); for them this is only the
 * fallback when the plugin still finds no usable sign-in.
 */
final class OwnDriveSignIn {
    /** "[drive](stage) message" from the plugin's drive errors, when the message says the sign-in is missing or stale. */
    private static final Pattern MISSING = Pattern.compile("^\\[([a-z0-9]+)\\]\\([^)]*\\)\\s*.*(配置中心|未配置|已失效|未登录).*", Pattern.DOTALL);
    /** Drives with an app sign-in, and the account field that holds it. */
    private static final Map<String, String> APP_ACCOUNTS = Map.of("quark", "quarkCookie", "uc", "ucCookie", "baidu", "baiduCookie");
    private static final Set<String> TERMINAL = Set.of("success", "expired", "error");
    static final long POLL_MILLIS = Long.getLong("tvbox.ownSignInPollMillis", 2_000);

    private OwnDriveSignIn() {}

    /** The drive a playback answer says has no sign-in, or null. */
    static String missingDrive(String result) {
        if (result == null || !result.trim().startsWith("{")) return null;
        try {
            var answer = new JSONObject(result);
            Object url = answer.opt("url");
            if (url instanceof String text && !text.isBlank() || url instanceof JSONArray list && list.length() > 0) return null;
            var match = MISSING.matcher(answer.optString("msg").trim());
            return match.matches() ? match.group(1) : null;
        } catch (org.json.JSONException malformed) { return null; }
    }

    /**
     * Signs the plugin in to {@code drive} through its own QR code. True once the plugin reports the
     * sign-in done; false when it has no such sign-in, the code expired, or the drive is one the app
     * should sign in to itself.
     */
    static boolean signIn(CloudDriveBridge bridge, String drive, Path folder) throws Exception {
        if (folder == null) return false;
        String field = APP_ACCOUNTS.get(drive);
        // With no app sign-in, the app asks for its own, which every source then uses.
        if (field != null && !bridge.hasAppAccount(field)) return false;
        var start = call(bridge, "loginStart", drive, null);
        String code = start == null ? "" : start.optString("qrUrl"), task = start == null ? "" : start.optString("taskId");
        if (start == null || start.optInt("code", -1) != 0 || code.isBlank() || task.isBlank()) {
            System.err.println("PLUGIN_OWN_SIGN_IN_UNAVAILABLE " + drive + " " + (start == null ? "-" : start.optString("msg")));
            return false;
        }
        HttpDiagnostics.extendForSignIn();
        LoginPrompt.publish(folder, drive, null, code);
        HttpDiagnostics.prompted();
        long until = System.currentTimeMillis() + LoginPrompt.SIGN_IN_MILLIS;
        while (System.currentTimeMillis() < until) {
            Thread.sleep(POLL_MILLIS);
            // The app stopped the request, or the viewer signed in on the drive's page in the app.
            HttpDiagnostics.checkpoint();
            var poll = call(bridge, "loginPoll", drive, task);
            String status = poll == null ? "" : poll.optString("status");
            if (!TERMINAL.contains(status)) continue;
            System.err.println("PLUGIN_OWN_SIGN_IN " + drive + " " + status);
            if (!status.equals("success")) return false;
            LoginPrompt.signedIn(folder, drive, account(bridge, drive));
            return true;
        }
        return false;
    }

    /** A Baidu sign-in the plugin made becomes the app's account too; other drives stay the plugin's. */
    private static Map<String, String> account(CloudDriveBridge bridge, String drive) {
        if (!drive.equals("baidu")) return Map.of();
        var credentials = call(bridge, "credentials", null, null);
        String cookie = credentials == null ? "" : credentials.optString("baiduCookie");
        return cookie.contains("BDUSS=") ? Map.of("baiduCookie", cookie) : Map.of();
    }

    /** The plugin's config-center answer to {@code action}, or null when it gave none. */
    private static JSONObject call(CloudDriveBridge bridge, String action, String drive, String task) {
        var params = new java.util.HashMap<String, String>(Map.of("do", "pan", "action", action));
        if (drive != null) params.put("provider", drive);
        if (task != null) params.put("taskId", task);
        String text;
        try { text = HttpDiagnostics.ownSignIn(() -> bridge.proxyText(params)); }
        catch (java.lang.reflect.InvocationTargetException failed) {
            // The host's own stops (the app gave up, the viewer signed in on the page) pass through.
            if (failed.getCause() instanceof Error stop) throw stop;
            System.err.println("PLUGIN_OWN_SIGN_IN_FAILED " + action + " " + failed.getCause());
            return null;
        } catch (Exception failed) {
            System.err.println("PLUGIN_OWN_SIGN_IN_FAILED " + action + " " + failed);
            return null;
        }
        if (text == null || !text.trim().startsWith("{")) return null;
        try { return new JSONObject(text); } catch (org.json.JSONException malformed) { return null; }
    }
}
