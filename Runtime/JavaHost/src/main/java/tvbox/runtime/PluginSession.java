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

    public String request(JSONObject params) throws Exception {
        PreparationProgress.loading();
        try { return performRequest(params); }
        finally { PreparationProgress.loading(); } // Flush the final throttled counters, also on failure.
    }

    private String performRequest(JSONObject params) throws Exception {
        HttpDiagnostics.reset();
        if (params.has("play")) {
            String required = params.optString("detailID", "");
            if (!required.isEmpty() && !required.equals(detailID)) {
                String detail = content(() -> spider.detailContent(List.of(required)), false);
                if (detail == null || detail.isBlank()) throw new IllegalStateException("The source returned no video details before playback");
                detailID = required;
            }
            String result = content(() -> spider.playerContent(params.optString("flag"), params.getString("play"), List.of()), false);
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
        if (result != null && !result.isBlank()) {
            if (checkInitialization && initializationWarning != null && emptyAllowed) checkInitialization(new JSONObject(result));
            return result;
        }
        // Empty home/category/search is valid for search-only or utility spiders.
        // Preserve remote failures instead of disguising them as an empty catalog.
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
