package android.database.sqlite;

import android.content.ContentValues;
import android.database.Cursor;
import tvbox.runtime.HostDatabase;

/**
 * The Android stub only throws "Stub!". This one has no SQL engine: queries are answered by
 * {@link HostDatabase} (the host app's settings plugins read), every other read is empty, and
 * writes are accepted and dropped.
 */
public final class SQLiteDatabase extends SQLiteClosable {
    public static final int CONFLICT_ROLLBACK = 1, CONFLICT_ABORT = 2, CONFLICT_FAIL = 3, CONFLICT_IGNORE = 4, CONFLICT_REPLACE = 5, CONFLICT_NONE = 0;
    public static final int SQLITE_MAX_LIKE_PATTERN_LENGTH = 50000;
    public static final int OPEN_READWRITE = 0, OPEN_READONLY = 1, NO_LOCALIZED_COLLATORS = 0x10;
    public static final int CREATE_IF_NECESSARY = 0x10000000, ENABLE_WRITE_AHEAD_LOGGING = 0x20000000, MAX_SQL_CACHE_SIZE = 100;

    public interface CursorFactory {
        Cursor newCursor(SQLiteDatabase db, SQLiteCursorDriver masterQuery, String editTable, SQLiteQuery query);
    }

    private final String path;
    private final boolean readOnly;
    private int version;
    private boolean open = true;
    private int transactions;

    private SQLiteDatabase(String path, boolean readOnly) { this.path = path; this.readOnly = readOnly; }

    public static SQLiteDatabase openDatabase(String path, CursorFactory factory, int flags) {
        return new SQLiteDatabase(path, (flags & OPEN_READONLY) != 0);
    }
    public static SQLiteDatabase openDatabase(String path, CursorFactory factory, int flags, android.database.DatabaseErrorHandler handler) {
        return openDatabase(path, factory, flags);
    }
    public static SQLiteDatabase openOrCreateDatabase(java.io.File file, CursorFactory factory) { return openDatabase(file.getPath(), factory, CREATE_IF_NECESSARY); }
    public static SQLiteDatabase openOrCreateDatabase(String path, CursorFactory factory) { return openDatabase(path, factory, CREATE_IF_NECESSARY); }
    public static SQLiteDatabase openOrCreateDatabase(String path, CursorFactory factory, android.database.DatabaseErrorHandler handler) { return openDatabase(path, factory, CREATE_IF_NECESSARY); }
    public static SQLiteDatabase create(CursorFactory factory) { return openDatabase(":memory:", factory, CREATE_IF_NECESSARY); }
    public static boolean deleteDatabase(java.io.File file) { return file.delete(); }
    public static int releaseMemory() { return 0; }

    @Override protected void onAllReferencesReleased() { open = false; }

    public Cursor rawQuery(String sql, String[] arguments) { return HostDatabase.query(path, sql, arguments); }
    public Cursor rawQuery(String sql, String[] arguments, android.os.CancellationSignal signal) { return rawQuery(sql, arguments); }
    public Cursor rawQueryWithFactory(CursorFactory factory, String sql, String[] arguments, String table) { return rawQuery(sql, arguments); }
    public Cursor rawQueryWithFactory(CursorFactory factory, String sql, String[] arguments, String table, android.os.CancellationSignal signal) { return rawQuery(sql, arguments); }
    public Cursor query(boolean distinct, String table, String[] columns, String selection, String[] arguments, String groupBy, String having, String orderBy, String limit) {
        return rawQuery(HostDatabase.select(distinct, table, columns, selection, groupBy, having, orderBy, limit), arguments);
    }
    public Cursor query(boolean distinct, String table, String[] columns, String selection, String[] arguments, String groupBy, String having, String orderBy, String limit, android.os.CancellationSignal signal) {
        return query(distinct, table, columns, selection, arguments, groupBy, having, orderBy, limit);
    }
    public Cursor queryWithFactory(CursorFactory factory, boolean distinct, String table, String[] columns, String selection, String[] arguments, String groupBy, String having, String orderBy, String limit) {
        return query(distinct, table, columns, selection, arguments, groupBy, having, orderBy, limit);
    }
    public Cursor queryWithFactory(CursorFactory factory, boolean distinct, String table, String[] columns, String selection, String[] arguments, String groupBy, String having, String orderBy, String limit, android.os.CancellationSignal signal) {
        return query(distinct, table, columns, selection, arguments, groupBy, having, orderBy, limit);
    }
    public Cursor query(String table, String[] columns, String selection, String[] arguments, String groupBy, String having, String orderBy) {
        return query(false, table, columns, selection, arguments, groupBy, having, orderBy, null);
    }
    public Cursor query(String table, String[] columns, String selection, String[] arguments, String groupBy, String having, String orderBy, String limit) {
        return query(false, table, columns, selection, arguments, groupBy, having, orderBy, limit);
    }

    public long insert(String table, String nullColumnHack, ContentValues values) { return -1; }
    public long insertOrThrow(String table, String nullColumnHack, ContentValues values) { return -1; }
    public long replace(String table, String nullColumnHack, ContentValues values) { return -1; }
    public long replaceOrThrow(String table, String nullColumnHack, ContentValues values) { return -1; }
    public long insertWithOnConflict(String table, String nullColumnHack, ContentValues values, int conflict) { return -1; }
    public int delete(String table, String where, String[] arguments) { return 0; }
    public int update(String table, ContentValues values, String where, String[] arguments) { return 0; }
    public int updateWithOnConflict(String table, ContentValues values, String where, String[] arguments, int conflict) { return 0; }
    public void execSQL(String sql) { }
    public void execSQL(String sql, Object[] arguments) { }

    public void beginTransaction() { transactions++; }
    public void beginTransactionNonExclusive() { transactions++; }
    public void beginTransactionWithListener(SQLiteTransactionListener listener) { transactions++; }
    public void beginTransactionWithListenerNonExclusive(SQLiteTransactionListener listener) { transactions++; }
    public void endTransaction() { if (transactions > 0) transactions--; }
    public void setTransactionSuccessful() { }
    public boolean inTransaction() { return transactions > 0; }
    public boolean isDbLockedByCurrentThread() { return false; }
    public boolean isDbLockedByOtherThreads() { return false; }
    public boolean yieldIfContended() { return false; }
    public boolean yieldIfContendedSafely() { return false; }
    public boolean yieldIfContendedSafely(long sleep) { return false; }
    public void setLockingEnabled(boolean enabled) { }

    public int getVersion() { return version; }
    public void setVersion(int version) { this.version = version; }
    public long getMaximumSize() { return Long.MAX_VALUE; }
    public long setMaximumSize(long size) { return size; }
    public long getPageSize() { return 4096; }
    public void setPageSize(long size) { }
    public boolean isReadOnly() { return readOnly; }
    public boolean isOpen() { return open; }
    public boolean needUpgrade(int newVersion) { return newVersion > version; }
    public final String getPath() { return path; }
    public void setLocale(java.util.Locale locale) { }
    public void setMaxSqlCacheSize(int size) { }
    public void setForeignKeyConstraintsEnabled(boolean enabled) { }
    public boolean enableWriteAheadLogging() { return true; }
    public void disableWriteAheadLogging() { }
    public boolean isWriteAheadLoggingEnabled() { return false; }
    public boolean isDatabaseIntegrityOk() { return true; }
    public java.util.Map<String, String> getSyncedTables() { return new java.util.HashMap<>(); }
    public static String findEditTable(String tables) { return tables; }
    @Override public String toString() { return "SQLiteDatabase: " + path; }
}
