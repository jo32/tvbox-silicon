package android.widget;

import android.view.View;
import android.view.ViewGroup;

public abstract class BaseAdapter implements ListAdapter, SpinnerAdapter {
    private final java.util.List<android.database.DataSetObserver> observers = new java.util.concurrent.CopyOnWriteArrayList<>();
    @Override public void registerDataSetObserver(android.database.DataSetObserver observer) { observers.add(observer); }
    @Override public void unregisterDataSetObserver(android.database.DataSetObserver observer) { observers.remove(observer); }
    public void notifyDataSetChanged() { for (var observer : observers) observer.onChanged(); }
    public void notifyDataSetInvalidated() { for (var observer : observers) observer.onInvalidated(); }
    @Override public boolean hasStableIds() { return false; }
    @Override public boolean areAllItemsEnabled() { return true; }
    @Override public boolean isEnabled(int position) { return true; }
    @Override public View getDropDownView(int position, View convertView, ViewGroup parent) { return getView(position, convertView, parent); }
    @Override public int getItemViewType(int position) { return 0; }
    @Override public int getViewTypeCount() { return 1; }
    @Override public boolean isEmpty() { return getCount() == 0; }
}
