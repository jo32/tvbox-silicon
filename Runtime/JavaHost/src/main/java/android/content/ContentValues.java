package android.content;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/** Column values for a database row. */
public final class ContentValues {
    private final HashMap<String, Object> values;
    public ContentValues() { values = new HashMap<>(8); }
    public ContentValues(int size) { values = new HashMap<>(size); }
    public ContentValues(ContentValues from) { values = new HashMap<>(from.values); }
    public void put(String key, String value) { values.put(key, value); }
    public void put(String key, Byte value) { values.put(key, value); }
    public void put(String key, Short value) { values.put(key, value); }
    public void put(String key, Integer value) { values.put(key, value); }
    public void put(String key, Long value) { values.put(key, value); }
    public void put(String key, Float value) { values.put(key, value); }
    public void put(String key, Double value) { values.put(key, value); }
    public void put(String key, Boolean value) { values.put(key, value); }
    public void put(String key, byte[] value) { values.put(key, value); }
    public void putAll(ContentValues other) { values.putAll(other.values); }
    public void putNull(String key) { values.put(key, null); }
    public int size() { return values.size(); }
    public boolean isEmpty() { return values.isEmpty(); }
    public void remove(String key) { values.remove(key); }
    public void clear() { values.clear(); }
    public boolean containsKey(String key) { return values.containsKey(key); }
    public Object get(String key) { return values.get(key); }
    public String getAsString(String key) { Object v = values.get(key); return v == null ? null : v.toString(); }
    public Long getAsLong(String key) { Object v = values.get(key); try { return v instanceof Number n ? n.longValue() : v == null ? null : Long.valueOf(v.toString()); } catch (NumberFormatException e) { return null; } }
    public Integer getAsInteger(String key) { Object v = values.get(key); try { return v instanceof Number n ? n.intValue() : v == null ? null : Integer.valueOf(v.toString()); } catch (NumberFormatException e) { return null; } }
    public Short getAsShort(String key) { Integer v = getAsInteger(key); return v == null ? null : v.shortValue(); }
    public Byte getAsByte(String key) { Integer v = getAsInteger(key); return v == null ? null : v.byteValue(); }
    public Double getAsDouble(String key) { Object v = values.get(key); try { return v instanceof Number n ? n.doubleValue() : v == null ? null : Double.valueOf(v.toString()); } catch (NumberFormatException e) { return null; } }
    public Float getAsFloat(String key) { Double v = getAsDouble(key); return v == null ? null : v.floatValue(); }
    public Boolean getAsBoolean(String key) { Object v = values.get(key); return v instanceof Boolean b ? b : v instanceof Number n ? n.intValue() != 0 : v == null ? null : Boolean.valueOf(v.toString()) || "1".equals(v.toString()); }
    public byte[] getAsByteArray(String key) { Object v = values.get(key); return v instanceof byte[] bytes ? bytes : null; }
    public Set<Map.Entry<String, Object>> valueSet() { return values.entrySet(); }
    public Set<String> keySet() { return values.keySet(); }
    @Override public boolean equals(Object other) { return other instanceof ContentValues o && values.equals(o.values); }
    @Override public int hashCode() { return values.hashCode(); }
    @Override public String toString() { StringBuilder b = new StringBuilder(); for (var e : values.entrySet()) { if (b.length() > 0) b.append(' '); b.append(e.getKey()).append('=').append(e.getValue()); } return b.toString(); }
}
