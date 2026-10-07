package android.database.sqlite;

public abstract class SQLiteClosable implements java.io.Closeable {
    private int references = 1;
    protected abstract void onAllReferencesReleased();
    public void acquireReference() { synchronized (this) { references++; } }
    public void releaseReference() {
        boolean released;
        synchronized (this) { released = --references == 0; }
        if (released) onAllReferencesReleased();
    }
    public void releaseReferenceFromContainer() { releaseReference(); }
    public void close() { releaseReference(); }
}
