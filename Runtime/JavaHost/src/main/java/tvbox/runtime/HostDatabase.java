package tvbox.runtime;

import android.database.Cursor;
import java.lang.reflect.Proxy;
import java.util.*;
import java.util.regex.*;

/**
 * Answers the SQL that plugins run against the host app's database. CatVod plugins are written for
 * FongMi TV, whose "tv" database keeps loaded subscriptions in Config(id, type, time, url, json,
 * name, logo, home, parse); type 0 is the video subscription and 1 the live one. Guards read
 * {@code SELECT url FROM Config WHERE type = 0 ORDER BY time DESC LIMIT 1} to learn the address the
 * user loaded. Anything else returns an empty result, as an empty database would.
 */
public final class HostDatabase {
    private HostDatabase() { }

    /** The subscription address the source was loaded from, set per request. */
    public static volatile String subscription;

    private static final Pattern CONFIG = Pattern.compile(
        "(?is)^\\s*select\\s+(.+?)\\s+from\\s+[`\"\\[]?config[`\"\\]]?(?:\\s+where\\s+(.+?))?(?:\\s+order\\s+by\\s+.+?)?(?:\\s+limit\\s+\\d+(?:\\s*,\\s*\\d+)?)?\\s*;?\\s*$");
    private static final Pattern TYPE = Pattern.compile("(?i)\\btype\\s*=\\s*('?)(\\d+|\\?)\\1");
    private static final List<String> CONFIG_COLUMNS = List.of("id", "type", "time", "url", "json", "name", "logo", "home", "parse");

    public static Cursor query(String path, String sql, String[] arguments) {
        String name = path == null ? "" : new java.io.File(path).getName();
        String url = subscription;
        Matcher config = sql == null ? null : CONFIG.matcher(sql);
        if (name.equals("tv") && url != null && !url.isEmpty() && config != null && config.matches()) {
            int type = 0;
            if (config.group(2) != null) {
                Matcher condition = TYPE.matcher(config.group(2));
                if (condition.find()) {
                    String value = condition.group(2);
                    try { type = Integer.parseInt(value.equals("?") ? (arguments != null && arguments.length > 0 ? arguments[0] : "0") : value); }
                    catch (NumberFormatException ignored) { type = -1; }
                }
            }
            List<String> columns = columns(config.group(1));
            if (type == 0 || type == 1) {
                Map<String, Object> row = Map.of("id", type + 1, "type", type, "time", System.currentTimeMillis(), "url", url);
                Object[] values = new Object[columns.size()];
                for (int i = 0; i < values.length; i++) values[i] = row.get(columns.get(i).toLowerCase(Locale.ROOT));
                System.err.println("HOST_DATABASE " + name + " Config type=" + type);
                return cursor(columns, List.<Object[]>of(values));
            }
            return cursor(columns, List.of());
        }
        System.err.println("HOST_DATABASE_EMPTY " + name + " " + (sql == null ? "" : sql.replaceAll("\\s+", " ")));
        return cursor(List.of(), List.of());
    }

    private static List<String> columns(String list) {
        if (list.trim().equals("*")) return CONFIG_COLUMNS;
        List<String> result = new ArrayList<>();
        for (String part : list.split(",")) {
            String column = part.trim().replaceAll("(?i)^.*\\s+as\\s+", "").replaceAll("[`\"\\[\\]]", "");
            int dot = column.lastIndexOf('.');
            result.add(dot >= 0 ? column.substring(dot + 1) : column);
        }
        return result;
    }

    /** The SQL SQLiteDatabase.query() would have built (SQLiteQueryBuilder.buildQueryString). */
    public static String select(boolean distinct, String table, String[] columns, String where, String groupBy, String having, String orderBy, String limit) {
        StringBuilder sql = new StringBuilder("SELECT ");
        if (distinct) sql.append("DISTINCT ");
        sql.append(columns == null || columns.length == 0 ? "*" : String.join(", ", columns)).append(" FROM ").append(table);
        if (where != null && !where.isEmpty()) sql.append(" WHERE ").append(where);
        if (groupBy != null && !groupBy.isEmpty()) sql.append(" GROUP BY ").append(groupBy);
        if (having != null && !having.isEmpty()) sql.append(" HAVING ").append(having);
        if (orderBy != null && !orderBy.isEmpty()) sql.append(" ORDER BY ").append(orderBy);
        if (limit != null && !limit.isEmpty()) sql.append(" LIMIT ").append(limit);
        return sql.toString();
    }

    /** A read-only cursor over fixed rows; Android's MatrixCursor is a stub here too. */
    public static Cursor cursor(List<String> columns, List<Object[]> rows) {
        int[] position = { -1 };
        boolean[] closed = { false };
        return (Cursor) Proxy.newProxyInstance(Cursor.class.getClassLoader(), new Class<?>[] { Cursor.class }, (proxy, method, args) -> {
            int count = rows.size();
            switch (method.getName()) {
                case "getCount": return count;
                case "getPosition": return position[0];
                case "move": return moveTo(position, count, position[0] + (int) args[0]);
                case "moveToPosition": return moveTo(position, count, (int) args[0]);
                case "moveToFirst": return moveTo(position, count, 0);
                case "moveToLast": return moveTo(position, count, count - 1);
                case "moveToNext": return moveTo(position, count, position[0] + 1);
                case "moveToPrevious": return moveTo(position, count, position[0] - 1);
                case "isFirst": return count > 0 && position[0] == 0;
                case "isLast": return count > 0 && position[0] == count - 1;
                case "isBeforeFirst": return count == 0 || position[0] < 0;
                case "isAfterLast": return count == 0 || position[0] >= count;
                case "getColumnCount": return columns.size();
                case "getColumnNames": return columns.toArray(new String[0]);
                case "getColumnName": return columns.get((int) args[0]);
                case "getColumnIndex": return index(columns, (String) args[0]);
                case "getColumnIndexOrThrow": {
                    int index = index(columns, (String) args[0]);
                    if (index < 0) throw new IllegalArgumentException("column '" + args[0] + "' does not exist");
                    return index;
                }
                case "close": closed[0] = true; return null;
                case "isClosed": return closed[0];
                case "deactivate": case "registerContentObserver": case "unregisterContentObserver":
                case "registerDataSetObserver": case "unregisterDataSetObserver": case "setNotificationUri": return null;
                case "requery": return true;
                case "getWantsAllOnMoveCalls": return false;
                case "getExtras": case "respond": return null; // android.os.Bundle is a stub here
                case "hashCode": return System.identityHashCode(proxy);
                case "equals": return proxy == args[0];
                case "toString": return "HostDatabase.Cursor" + columns;
                default: break;
            }
            if (args == null || args.length != 1 || !(args[0] instanceof Integer column)) return defaultValue(method.getReturnType());
            if (position[0] < 0 || position[0] >= count) throw new IllegalStateException("Cursor is not on a row");
            Object value = rows.get(position[0])[column];
            return switch (method.getName()) {
                case "getString" -> value == null ? null : String.valueOf(value);
                case "isNull" -> value == null;
                case "getType" -> value == null ? 0 : value instanceof Number ? (value instanceof Double || value instanceof Float ? 2 : 1) : value instanceof byte[] ? 4 : 3;
                case "getBlob" -> value instanceof byte[] bytes ? bytes : value == null ? null : String.valueOf(value).getBytes(java.nio.charset.StandardCharsets.UTF_8);
                case "getInt" -> number(value).intValue();
                case "getLong" -> number(value).longValue();
                case "getShort" -> number(value).shortValue();
                case "getFloat" -> number(value).floatValue();
                case "getDouble" -> number(value).doubleValue();
                default -> defaultValue(method.getReturnType());
            };
        });
    }

    private static boolean moveTo(int[] position, int count, int target) {
        position[0] = Math.max(-1, Math.min(count, target));
        return position[0] >= 0 && position[0] < count;
    }

    private static int index(List<String> columns, String name) {
        for (int i = 0; i < columns.size(); i++) if (columns.get(i).equalsIgnoreCase(name)) return i;
        return -1;
    }

    private static Number number(Object value) {
        if (value instanceof Number number) return number;
        try { return value == null ? 0 : Double.parseDouble(String.valueOf(value)); }
        catch (NumberFormatException ignored) { return 0; }
    }

    private static Object defaultValue(Class<?> type) {
        if (type == boolean.class) return false;
        if (type == int.class || type == short.class || type == byte.class || type == char.class) return 0;
        if (type == long.class) return 0L;
        if (type == float.class) return 0f;
        if (type == double.class) return 0d;
        return null;
    }
}
