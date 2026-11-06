package android.util;

import java.util.ArrayList;
import java.util.LinkedHashMap;

/** Insertion-ordered map with Android's index accessors. */
public class ArrayMap<K, V> extends LinkedHashMap<K, V> {
    public ArrayMap() { }
    public ArrayMap(int capacity) { super(Math.max(capacity, 1)); }
    public K keyAt(int index) { return new ArrayList<>(keySet()).get(index); }
    public V valueAt(int index) { return new ArrayList<>(values()).get(index); }
    public int indexOfKey(Object key) { return new ArrayList<>(keySet()).indexOf(key); }
    public V removeAt(int index) { return remove(keyAt(index)); }
}
