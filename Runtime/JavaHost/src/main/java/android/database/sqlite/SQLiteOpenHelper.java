package android.database.sqlite;

import android.content.Context;

/** Opens a {@link SQLiteDatabase} without an engine; onCreate runs once per process for each database. */
public abstract class SQLiteOpenHelper {
    private static final java.util.Set<String> created = java.util.concurrent.ConcurrentHashMap.newKeySet();
    private final Context context;
    private final String name;
    private final int version;
    private SQLiteDatabase database;

    public SQLiteOpenHelper(Context context, String name, SQLiteDatabase.CursorFactory factory, int version) {
        this.context = context; this.name = name; this.version = version;
    }
    public SQLiteOpenHelper(Context context, String name, SQLiteDatabase.CursorFactory factory, int version, android.database.DatabaseErrorHandler handler) {
        this(context, name, factory, version);
    }
    public String getDatabaseName() { return name; }
    public void setWriteAheadLoggingEnabled(boolean enabled) { }
    public synchronized SQLiteDatabase getWritableDatabase() {
        if (database != null && database.isOpen()) return database;
        String path = name == null ? ":memory:" : context.getDatabasePath(name).getPath();
        database = SQLiteDatabase.openDatabase(path, null, SQLiteDatabase.CREATE_IF_NECESSARY);
        onConfigure(database);
        if (created.add(path)) onCreate(database);
        database.setVersion(version);
        onOpen(database);
        return database;
    }
    public SQLiteDatabase getReadableDatabase() { return getWritableDatabase(); }
    public synchronized void close() { if (database != null) database.close(); database = null; }
    public void onConfigure(SQLiteDatabase db) { }
    public abstract void onCreate(SQLiteDatabase db);
    public abstract void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion);
    public void onDowngrade(SQLiteDatabase db, int oldVersion, int newVersion) { }
    public void onOpen(SQLiteDatabase db) { }
}
