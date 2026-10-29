package tvbox.runtime;

import com.github.catvod.crawler.Spider;
import org.json.JSONObject;
import java.util.List;

/** Keeps one spider and its detail-dependent playback state alive across requests. */
public final class PluginSession {
    private final Spider spider;
    private final Throwable initializationWarning;
    private String detailID;
    private final CloudDriveBridge bridge;

    public PluginSession(Spider spider) { this(spider, null); }
    public PluginSession(Spider spider, Throwable initializationWarning) {
        this(spider, initializationWarning, null);
    }
    public PluginSession(Spider spider, Throwable initializationWarning, CloudDriveBridge bridge) {
        this.spider = spider; this.initializationWarning = initializationWarning; this.bridge = bridge;
    }

    public String recoverProxy(String address) throws Exception {
        return bridge == null ? null : bridge.recoverProxy(address);
    }

    public String directMedia(String address) throws Exception {
        return bridge == null ? null : bridge.directMedia(address);
    }

    /**
     * {@code _stopAt} (set by the host) is when the request must end: the app abandoned it, or
     * {@code _deadline} seconds passed once the spider started working on it.
     */
    public String request(JSONObject params) throws Exception {
        var stopAt = params.opt("_stopAt") instanceof java.util.concurrent.atomic.AtomicLong value ? value : new java.util.concurrent.atomic.AtomicLong();
        long seconds = params.optLong("_deadline", 0);
        if (seconds > 0) {
            long deadline = System.currentTimeMillis() + seconds * 1000;
            stopAt.accumulateAndGet(deadline, (current, next) -> current == 0 ? next : Math.min(current, next));
        }
        String kind = params.has("play") ? "play flag=" + params.optString("flag") : params.has("ids") ? "detail"
            : params.has("wd") ? "search" : params.has("t") ? "category" : "home";
        System.err.println("PLUGIN_REQUEST " + java.time.LocalTime.now().withNano(0) + " " + kind + " deadline=" + seconds + "s");
        HttpDiagnostics.beginRequest(params.has("play"), stopAt, params.optString("_folder", null));
        PreparationProgress.loading();
        try { return performRequest(params); }
        finally { PreparationProgress.loading(); HttpDiagnostics.endRequest(); } // Flush the final throttled counters, also on failure.
    }

    private String performRequest(JSONObject params) throws Exception {
        if (params.has("play")) {
            String required = params.optString("detailID", "");
            if (!required.isEmpty() && !required.equals(detailID)) {
                String detail = content(() -> spider.detailContent(List.of(required)), false);
                if (detail == null || detail.isBlank()) throw new IllegalStateException("The source returned no video details before playback");
                detailID = required;
            }
            Operation play = () -> spider.playerContent(params.optString("flag"), params.getString("play"), List.of());
            String result = content(play, false);
            // The plugin has no sign-in for this line's drive: it signs in itself (the app shows its code), then the line is asked again.
            String drive = bridge == null ? null : OwnDriveSignIn.missingDrive(result);
            if (drive != null && OwnDriveSignIn.signIn(bridge, drive, HttpDiagnostics.promptFolder())) result = content(play, false);
            return bridge == null ? result : bridge.playback(result);
        }
        if (params.has("ids")) {
            String id = params.getString("ids");
            String result = content(() -> spider.detailContent(List.of(id)), false);
            detailID = id;
            return result;
        }
        if (params.has("wd")) return content(() -> spider.searchContent(params.getString("wd"), false, params.optString("pg", "1")), true);
        if (params.has("t")) return content(() -> spider.categoryContent(params.getString("t"), params.optString("pg", "1"), true, new java.util.HashMap<>()), true);
        JSONObject home = new JSONObject(content(() -> spider.homeContent(true), true, false));
        JSONObject recommendations = new JSONObject(content(() -> spider.homeVideoContent(), true, false));
        var videos = recommendations.optJSONArray("list");
        if (videos != null && videos.length() > 0) home.put("list", videos);
        checkInitialization(home);
        return home.toString();
    }

    /** Releases this source only; a shared plugin runtime and its native guard stay loaded. */
    public void closeSource() throws Exception {
        try { spider.destroy(); }
        finally { if (bridge != null) bridge.close(); }
    }

    public void close() throws Exception {
        try { spider.destroy(); }
        finally {
            android.os.Looper.shutdown();
            if (bridge != null) bridge.close();
            AndroidNativeRuntime.close();
            NativeCalls.close();
            if (spider.getClass().getClassLoader() instanceof java.net.URLClassLoader loader) loader.close();
        }
    }

    private String content(Operation operation, boolean emptyAllowed) throws Exception {
        return content(operation, emptyAllowed, true);
    }
    private String content(Operation operation, boolean emptyAllowed, boolean checkInitialization) throws Exception {
        String result;
        try { result = operation.run(); }
        catch (org.json.JSONException malformed) {
            HttpDiagnostics.throwIfFailed();
            throw malformed;
        }
        // A spider may swallow even a host handoff and return empty/partial content.
        HttpDiagnostics.throwIfLoginRequired();
        if (result != null && !result.isBlank()) {
            if (checkInitialization && initializationWarning != null && emptyAllowed) checkInitialization(new JSONObject(result));
            return result;
        }
        // Empty home/category/search is valid for search-only or utility spiders.
        // Preserve remote failures instead of disguising them as an empty catalog. A spider that
        // caught the host's stop returns nothing: report the stop, not an empty answer.
        HttpDiagnostics.throwIfStopped();
        HttpDiagnostics.throwIfFailed();
        if (checkInitialization && initializationWarning != null) checkInitialization(new JSONObject());
        if (emptyAllowed) return "{}";
        throw new EmptyContentException();
    }

    private void checkInitialization(JSONObject object) {
        if (initializationWarning == null) return;
        var list = object.optJSONArray("list");
        var categories = object.optJSONArray("class");
        if ((list == null || list.length() == 0) && (categories == null || categories.length() == 0)) {
            throw new IllegalStateException("Plugin initialization was incomplete: " + initializationWarning, initializationWarning);
        }
    }

    @FunctionalInterface private interface Operation { String run() throws Exception; }
    public static final class EmptyContentException extends Exception {
        public EmptyContentException() { super("The plugin returned no content"); }
    }
}
