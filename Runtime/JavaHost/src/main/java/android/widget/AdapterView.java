package android.widget;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;

/** A view whose rows come from an adapter; tapping a row runs the item click listener. */
public abstract class AdapterView<T extends Adapter> extends ViewGroup {
    public static final int INVALID_POSITION = -1, ITEM_VIEW_TYPE_IGNORE = -1, ITEM_VIEW_TYPE_HEADER_OR_FOOTER = -2;
    public static final long INVALID_ROW_ID = Long.MIN_VALUE;
    public interface OnItemClickListener { void onItemClick(AdapterView<?> parent, View view, int position, long id); }
    public interface OnItemLongClickListener { boolean onItemLongClick(AdapterView<?> parent, View view, int position, long id); }
    public interface OnItemSelectedListener { void onItemSelected(AdapterView<?> parent, View view, int position, long id); void onNothingSelected(AdapterView<?> parent); }

    private OnItemClickListener itemClick;
    private OnItemLongClickListener itemLongClick;
    private OnItemSelectedListener itemSelected;
    int selectedPosition = INVALID_POSITION;
    private View emptyView;

    public AdapterView(Context context) { super(context); }
    public AdapterView(Context context, android.util.AttributeSet attrs) { super(context); }
    public AdapterView(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }

    public abstract T getAdapter();
    public abstract void setAdapter(T adapter);
    public abstract View getSelectedView();
    public abstract void setSelection(int position);
    public void setOnItemClickListener(OnItemClickListener listener) { itemClick = listener; }
    public final OnItemClickListener getOnItemClickListener() { return itemClick; }
    public void setOnItemLongClickListener(OnItemLongClickListener listener) { itemLongClick = listener; }
    public final OnItemLongClickListener getOnItemLongClickListener() { return itemLongClick; }
    public void setOnItemSelectedListener(OnItemSelectedListener listener) { itemSelected = listener; }
    public final OnItemSelectedListener getOnItemSelectedListener() { return itemSelected; }
    public boolean performItemClick(View view, int position, long id) {
        if (itemClick == null) return false;
        itemClick.onItemClick(this, view, position, id);
        return true;
    }
    public int getCount() { T adapter = getAdapter(); return adapter == null ? 0 : adapter.getCount(); }
    public Object getItemAtPosition(int position) { T adapter = getAdapter(); return adapter == null || position < 0 || position >= adapter.getCount() ? null : adapter.getItem(position); }
    public long getItemIdAtPosition(int position) { T adapter = getAdapter(); return adapter == null || position < 0 || position >= adapter.getCount() ? INVALID_ROW_ID : adapter.getItemId(position); }
    public int getSelectedItemPosition() { return selectedPosition; }
    public long getSelectedItemId() { return getItemIdAtPosition(selectedPosition); }
    public Object getSelectedItem() { return getItemAtPosition(selectedPosition); }
    public int getFirstVisiblePosition() { return 0; }
    public int getLastVisiblePosition() { return getCount() - 1; }
    public int getPositionForView(View view) { for (View v = view; v != null; v = v.getParent() instanceof View up ? up : null) { if (v.getParent() == this) return indexOfChild(v); } return INVALID_POSITION; }
    public void setEmptyView(View view) { emptyView = view; }
    public View getEmptyView() { return emptyView; }
    void selected(int position) {
        selectedPosition = position;
        if (itemSelected != null) { if (position == INVALID_POSITION) itemSelected.onNothingSelected(this); else itemSelected.onItemSelected(this, getChildAt(position), position, getItemIdAtPosition(position)); }
    }
    @Override protected ViewGroup.LayoutParams generateDefaultLayoutParams() { return new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT); }
}
