package tvbox.runtime;
import android.content.SharedPreferences;
import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
public final class FilePreferences implements SharedPreferences {
    private final Path file;
    private JsonObject values;
    private final Set<OnSharedPreferenceChangeListener> listeners = new HashSet<>();
    public FilePreferences(Path file) {
        this.file = file;
        try { values = JsonParser.parseString(Files.readString(file)).getAsJsonObject(); }
        catch (Exception e) { values = new JsonObject(); }
    }
    public synchronized Map<String,?> getAll() { return new Gson().fromJson(values, Map.class); }
    public synchronized String getString(String key, String fallback) { return values.has(key) ? values.get(key).getAsString() : fallback; }
    public synchronized Set<String> getStringSet(String key, Set<String> fallback) {
        if (!values.has(key)) return fallback;
        Set<String> result = new HashSet<>(); values.getAsJsonArray(key).forEach(v -> result.add(v.getAsString())); return result;
    }
    public synchronized int getInt(String key, int fallback) { return values.has(key) ? values.get(key).getAsInt() : fallback; }
    public synchronized long getLong(String key, long fallback) { return values.has(key) ? values.get(key).getAsLong() : fallback; }
    public synchronized float getFloat(String key, float fallback) { return values.has(key) ? values.get(key).getAsFloat() : fallback; }
    public synchronized boolean getBoolean(String key, boolean fallback) { return values.has(key) ? values.get(key).getAsBoolean() : fallback; }
    public synchronized boolean contains(String key) { return values.has(key); }
    public synchronized void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) { listeners.add(listener); }
    public synchronized void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) { listeners.remove(listener); }
    public Editor edit() {
        return new Editor() {
            final Map<String, JsonElement> changes = new HashMap<>(); boolean clear;
            public Editor putString(String k, String v) { changes.put(k,v==null ? null : new JsonPrimitive(v)); return this; }
            public Editor putStringSet(String k, Set<String> v) { changes.put(k,v==null ? null : new Gson().toJsonTree(v)); return this; }
            public Editor putInt(String k, int v) { changes.put(k,new JsonPrimitive(v)); return this; }
            public Editor putLong(String k, long v) { changes.put(k,new JsonPrimitive(v)); return this; }
            public Editor putFloat(String k, float v) { changes.put(k,new JsonPrimitive(v)); return this; }
            public Editor putBoolean(String k, boolean v) { changes.put(k,new JsonPrimitive(v)); return this; }
            public Editor remove(String k) { changes.put(k,null); return this; }
            public Editor clear() { clear=true; return this; }
            public boolean commit() {
                synchronized (FilePreferences.this) {
                    if (clear) values = new JsonObject();
                    changes.forEach((key,value) -> { if(value==null) values.remove(key); else values.add(key,value); });
                    try {
                        Files.createDirectories(file.getParent());
                        Path temp = Files.createTempFile(file.getParent(),"prefs-",".tmp");
                        Files.writeString(temp,values.toString()); Files.move(temp,file,StandardCopyOption.REPLACE_EXISTING);
                    } catch (Exception e) { return false; }
                    for(String key:changes.keySet()) for(var listener:listeners) listener.onSharedPreferenceChanged(FilePreferences.this,key);
                    return true;
                }
            }
            public void apply() { commit(); }
        };
    }
}
