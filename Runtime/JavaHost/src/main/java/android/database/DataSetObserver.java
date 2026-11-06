package android.database;

/** Hears that an adapter's data changed (the stub's constructor would throw). */
public abstract class DataSetObserver {
    public DataSetObserver() { }
    public void onChanged() { }
    public void onInvalidated() { }
}
