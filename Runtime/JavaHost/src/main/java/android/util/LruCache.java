package android.util;

import java.util.LinkedHashMap;
import java.util.Map;

/** Android's LruCache contract: access-ordered entries, evicted once the summed sizeOf exceeds maxSize. */
public class LruCache<K, V> {
    private final LinkedHashMap<K, V> map;
    private int size, maxSize, putCount, createCount, evictionCount, hitCount, missCount;

    public LruCache(int maxSize) {
        if (maxSize <= 0) throw new IllegalArgumentException("maxSize <= 0");
        this.maxSize = maxSize;
        this.map = new LinkedHashMap<>(0, 0.75f, true);
    }

    public void resize(int maxSize) {
        if (maxSize <= 0) throw new IllegalArgumentException("maxSize <= 0");
        synchronized (this) { this.maxSize = maxSize; }
        trimToSize(maxSize);
    }

    public final V get(K key) {
        if (key == null) throw new NullPointerException("key == null");
        synchronized (this) {
            V value = map.get(key);
            if (value != null) { hitCount++; return value; }
            missCount++;
        }
        V created = create(key);
        if (created == null) return null;
        V previous;
        synchronized (this) {
            createCount++;
            previous = map.put(key, created);
            if (previous != null) map.put(key, previous);
            else size += safeSizeOf(key, created);
        }
        if (previous != null) { entryRemoved(false, key, created, previous); return previous; }
        trimToSize(maxSize);
        return created;
    }

    public final V put(K key, V value) {
        if (key == null || value == null) throw new NullPointerException("key == null || value == null");
        V previous;
        synchronized (this) {
            putCount++;
            size += safeSizeOf(key, value);
            previous = map.put(key, value);
            if (previous != null) size -= safeSizeOf(key, previous);
        }
        if (previous != null) entryRemoved(false, key, previous, value);
        trimToSize(maxSize);
        return previous;
    }

    public void trimToSize(int maxSize) {
        while (true) {
            K key; V value;
            synchronized (this) {
                if (size <= maxSize || map.isEmpty()) break;
                Map.Entry<K, V> eldest = map.entrySet().iterator().next();
                key = eldest.getKey(); value = eldest.getValue();
                map.remove(key);
                size -= safeSizeOf(key, value);
                evictionCount++;
            }
            entryRemoved(true, key, value, null);
        }
    }

    public final V remove(K key) {
        if (key == null) throw new NullPointerException("key == null");
        V previous;
        synchronized (this) {
            previous = map.remove(key);
            if (previous != null) size -= safeSizeOf(key, previous);
        }
        if (previous != null) entryRemoved(false, key, previous, null);
        return previous;
    }

    protected void entryRemoved(boolean evicted, K key, V oldValue, V newValue) { }
    protected V create(K key) { return null; }
    protected int sizeOf(K key, V value) { return 1; }

    private int safeSizeOf(K key, V value) {
        int result = sizeOf(key, value);
        if (result < 0) throw new IllegalStateException("Negative size: " + key + "=" + value);
        return result;
    }

    public final void evictAll() { trimToSize(-1); }
    public synchronized final int size() { return size; }
    public synchronized final int maxSize() { return maxSize; }
    public synchronized final int hitCount() { return hitCount; }
    public synchronized final int missCount() { return missCount; }
    public synchronized final int createCount() { return createCount; }
    public synchronized final int putCount() { return putCount; }
    public synchronized final int evictionCount() { return evictionCount; }
    public synchronized final Map<K, V> snapshot() { return new LinkedHashMap<>(map); }
    @Override public synchronized final String toString() {
        int accesses = hitCount + missCount;
        return String.format("LruCache[maxSize=%d,hits=%d,misses=%d,hitRate=%d%%]", maxSize, hitCount, missCount, accesses != 0 ? 100 * hitCount / accesses : 0);
    }
}
