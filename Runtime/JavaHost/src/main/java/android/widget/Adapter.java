package android.widget;

import android.view.View;
import android.view.ViewGroup;

public interface Adapter {
    int IGNORE_ITEM_VIEW_TYPE = -1, NO_SELECTION = Integer.MIN_VALUE;
    void registerDataSetObserver(android.database.DataSetObserver observer);
    void unregisterDataSetObserver(android.database.DataSetObserver observer);
    int getCount();
    Object getItem(int position);
    long getItemId(int position);
    boolean hasStableIds();
    View getView(int position, View convertView, ViewGroup parent);
    int getItemViewType(int position);
    int getViewTypeCount();
    boolean isEmpty();
}
