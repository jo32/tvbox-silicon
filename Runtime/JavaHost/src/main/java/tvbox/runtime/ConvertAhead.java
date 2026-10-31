package tvbox.runtime;

import java.nio.file.Path;
import java.util.*;
import java.util.function.BooleanSupplier;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Converts the classes a plugin archive's sources are likely to need before anyone opens them
 * ({@code {"command":"convertAhead"}}, issue #274). No runtime opens and no plugin code runs: this only
 * fills the conversion cache that a later request reuses.
 *
 * <p>The classes are the sources' spider classes, then the classes their code reaches within three
 * steps, most shared first: a class that many spiders reach (the archive's HTTP, JSON and crypto helpers)
 * is more likely to be needed than one only a single spider reaches. On FTY's archive this covered about a
 * third of what browsing a few sources converted, and a bit over half of what it converted was used. An
 * archive whose classes are encrypted (an FTY guard) holds none of the spiders and is done at once.
 *
 * <p>Each call converts at most {@code batch} classes and returns, so the app can check the device between
 * calls. It also stops early while a plugin request is in flight or the heap is short.
 */
public final class ConvertAhead {
    /** The archive being prepared. One at a time: the app prepares archives one after another. */
    private record Plan(String jar, LazyDexArchive archive, List<String> classes) {}
    /** Volatile, not locked: a memory-pressure release must not wait for a running batch. */
    private static volatile Plan plan;
    private static final int DEPTH = 3;

    private ConvertAhead() {}

    /**
     * Input: {@code jar}, {@code conversionCache}, {@code spiders} (class names without the
     * {@code com.github.catvod.spider.} package), {@code limit} (classes per archive) and {@code batch}.
     * Output: {@code converted}, {@code reused}, {@code planned}, {@code remaining}, {@code done},
     * {@code stopped} (why a batch ended early) and {@code host} (the converter version the work is for).
     */
    public static synchronized JSONObject run(JSONObject input, BooleanSupplier busy) throws Exception {
        String jar = input.getString("jar");
        int limit = input.optInt("limit", 300), batch = Math.max(1, input.optInt("batch", 10));
        var result = new JSONObject().put("host", BytecodeCompatibility.VERSION);
        Plan current = plan;
        if (current == null || !current.jar().equals(jar)) {
            plan = null; // Release the previous archive's index before reading the next one.
            var interrupted = new JSONObject().put("host", BytecodeCompatibility.VERSION).put("converted", 0).put("reused", 0).put("next", input.optInt("from", 0)).put("done", false).put("stopped", "busy");
            if (busy.getAsBoolean()) return interrupted;
            var archive = new LazyDexArchive(jar, Path.of(input.getString("conversionCache")));
            List<String> spiders = new ArrayList<>();
            JSONArray names = input.optJSONArray("spiders");
            for (int i = 0; names != null && i < names.length(); i++) spiders.add("com.github.catvod.spider." + names.getString(i));
            spiders.add("com.github.catvod.spider.Init");
            List<String> classes = likely(archive, spiders, limit, busy);
            if (classes == null) return interrupted;
            current = new Plan(jar, archive, classes);
            plan = current;
            System.err.println("CONVERT_AHEAD_PLAN " + Path.of(jar).getFileName() + " spiders=" + spiders.size() + " classes=" + classes.size() + " of " + archive.size());
        }
        int converted = 0, reused = 0, index = input.optInt("from", 0);
        String stopped = "";
        List<String> classes = current.classes();
        while (index < classes.size() && converted < batch) {
            if (busy.getAsBoolean()) { stopped = "busy"; break; }
            if (HeapBudget.low() || plan != current) { stopped = "memory"; break; }
            String name = classes.get(index);
            try {
                if (current.archive().converted(name)) reused++;
                else { current.archive().prepare(name); converted++; }
            } catch (Exception broken) {
                // The request that needs it reports it; this only prepares.
                System.err.println("CONVERT_AHEAD_FAILED " + name + " " + broken);
            } catch (OutOfMemoryError exhausted) {
                stopped = "memory"; break;
            }
            index++;
        }
        boolean done = index >= classes.size();
        if (done && plan == current) plan = null;
        System.err.println("CONVERT_AHEAD " + Path.of(jar).getFileName() + " converted=" + converted + " reused=" + reused + " next=" + index + "/" + classes.size() + (stopped.isEmpty() ? "" : " stopped=" + stopped) + " " + HeapBudget.describe());
        return result.put("converted", converted).put("reused", reused).put("planned", classes.size()).put("next", index)
            .put("remaining", classes.size() - index).put("done", done).put("stopped", stopped);
    }

    /** Forgets the archive being prepared (the app gave up on it, or memory is short). */
    static void release() { plan = null; }

    /**
     * Up to {@code limit} classes of the archive: the spiders, then what they reach, most shared first.
     * Null when a request started meanwhile (reading every reached class's code takes a while interpreted).
     */
    public static List<String> likely(LazyDexArchive archive, List<String> spiders, int limit, BooleanSupplier busy) {
        List<String> roots = new ArrayList<>(new LinkedHashSet<>(spiders));
        roots.removeIf(name -> !archive.contains(name));
        Map<String, Integer> reachedBy = new HashMap<>(), depth = new HashMap<>();
        Map<String, List<String>> references = new HashMap<>();
        for (String root : roots) {
            Set<String> reached = new HashSet<>(List.of(root));
            List<String> level = List.of(root);
            for (int step = 1; step <= DEPTH && !level.isEmpty(); step++) {
                List<String> next = new ArrayList<>();
                for (String name : level) {
                    if (!references.containsKey(name) && busy.getAsBoolean()) return null;
                    for (String target : references.computeIfAbsent(name, archive::references)) {
                        if (reached.add(target)) { next.add(target); depth.merge(target, step, Math::min); }
                    }
                }
                level = next;
            }
            reached.remove(root);
            for (String name : reached) reachedBy.merge(name, 1, Integer::sum);
        }
        List<String> ordered = new ArrayList<>(roots);
        List<String> reached = new ArrayList<>(reachedBy.keySet());
        reached.removeAll(roots);
        reached.sort(Comparator.comparing((String name) -> -reachedBy.get(name)).thenComparing(depth::get).thenComparing(name -> name));
        ordered.addAll(reached);
        return ordered.size() > limit ? new ArrayList<>(ordered.subList(0, limit)) : ordered;
    }
}
