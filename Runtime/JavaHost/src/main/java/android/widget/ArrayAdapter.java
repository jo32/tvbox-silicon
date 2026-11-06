package android.widget;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;

/** Rows are plain TextViews (no layout resources ship with a plugin) showing each item's toString. */
public class ArrayAdapter<T> extends BaseAdapter {
    private final Context context;
    private final List<T> objects;
    private boolean notifyOnChange = true;

    public ArrayAdapter(Context context, int resource) { this(context, resource, 0, new ArrayList<>()); }
    public ArrayAdapter(Context context, int resource, int textViewResourceId) { this(context, resource, textViewResourceId, new ArrayList<>()); }
    public ArrayAdapter(Context context, int resource, T[] objects) { this(context, resource, 0, new ArrayList<>(Arrays.asList(objects))); }
    public ArrayAdapter(Context context, int resource, int textViewResourceId, T[] objects) { this(context, resource, textViewResourceId, new ArrayList<>(Arrays.asList(objects))); }
    public ArrayAdapter(Context context, int resource, List<T> objects) { this(context, resource, 0, objects); }
    public ArrayAdapter(Context context, int resource, int textViewResourceId, List<T> objects) { this.context = context; this.objects = objects; }

    public Context getContext() { return context; }
    @Override public int getCount() { return objects.size(); }
    @Override public T getItem(int position) { return objects.get(position); }
    @Override public long getItemId(int position) { return position; }
    public int getPosition(T item) { return objects.indexOf(item); }
    public void add(T item) { objects.add(item); changed(); }
    public void addAll(Collection<? extends T> items) { objects.addAll(items); changed(); }
    @SafeVarargs public final void addAll(T... items) { objects.addAll(Arrays.asList(items)); changed(); }
    public void insert(T item, int index) { objects.add(index, item); changed(); }
    public void remove(T item) { objects.remove(item); changed(); }
    public void clear() { objects.clear(); changed(); }
    public void sort(Comparator<? super T> comparator) { objects.sort(comparator); changed(); }
    public void setNotifyOnChange(boolean value) { notifyOnChange = value; }
    public void setDropDownViewResource(int resource) { }
    @Override public void notifyDataSetChanged() { super.notifyDataSetChanged(); notifyOnChange = true; }
    private void changed() { if (notifyOnChange) notifyDataSetChanged(); }
    @Override public View getView(int position, View convertView, ViewGroup parent) {
        TextView row = convertView instanceof TextView reused ? reused : new TextView(context);
        T item = getItem(position);
        row.setText(item instanceof CharSequence text ? text : String.valueOf(item));
        return row;
    }
}
