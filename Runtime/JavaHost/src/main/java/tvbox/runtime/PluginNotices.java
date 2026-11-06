package tvbox.runtime;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

/**
 * The toasts a plugin shows. While one of its settings runs (Spider.action) or its window is open, the app
 * shows them, as TVBox does; toasts from browsing are dropped when a setting starts.
 */
public final class PluginNotices {
    private static final ArrayDeque<String> pending = new ArrayDeque<>();
    private PluginNotices() { }

    public static synchronized void add(CharSequence text) {
        if (text == null) return;
        String notice = text.toString().trim();
        if (notice.isEmpty() || pending.contains(notice)) return;
        pending.add(notice);
        while (pending.size() > 20) pending.removeFirst();
    }

    public static synchronized boolean pending() { return !pending.isEmpty(); }

    public static synchronized List<String> take() {
        List<String> seen = new ArrayList<>(pending);
        pending.clear();
        return seen;
    }
}
