package tvbox.runtime;

import java.util.ArrayList;
import java.util.List;

/** The toasts a plugin shows while one of its actions runs (Spider.action), handed back to the app as the action's answer. */
public final class PluginNotices {
    private static List<String> collecting;
    private PluginNotices() { }

    public static synchronized void start() { collecting = new ArrayList<>(); }

    public static synchronized void add(CharSequence text) {
        if (collecting == null || text == null) return;
        String notice = text.toString().trim();
        if (!notice.isEmpty() && !collecting.contains(notice)) collecting.add(notice);
    }

    public static synchronized List<String> stop() {
        List<String> seen = collecting == null ? List.of() : collecting;
        collecting = null;
        return seen;
    }
}
