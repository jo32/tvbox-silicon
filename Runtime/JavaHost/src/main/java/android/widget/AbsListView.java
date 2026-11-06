package android.widget;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import java.util.ArrayList;
import java.util.List;

/**
 * A scrolling list of adapter rows. All rows are real children (there is no recycling on a screen this host does
 * not draw), so plugins can style them with getChildAt; a tap on a row checks it in the choice mode and runs the
 * item click listener.
 */
public abstract class AbsListView extends AdapterView<ListAdapter> {
    public static final int CHOICE_MODE_NONE = 0, CHOICE_MODE_SINGLE = 1, CHOICE_MODE_MULTIPLE = 2, CHOICE_MODE_MULTIPLE_MODAL = 3;
    public static final int TRANSCRIPT_MODE_DISABLED = 0;
    public interface OnScrollListener {
        int SCROLL_STATE_IDLE = 0, SCROLL_STATE_TOUCH_SCROLL = 1, SCROLL_STATE_FLING = 2;
        void onScrollStateChanged(AbsListView view, int scrollState);
        void onScroll(AbsListView view, int firstVisibleItem, int visibleItemCount, int totalItemCount);
    }
    public static class LayoutParams extends ViewGroup.LayoutParams {
        public LayoutParams(int width, int height) { super(width, height); }
        public LayoutParams(int width, int height, int viewType) { super(width, height); }
        public LayoutParams(ViewGroup.LayoutParams source) { super(source); }
        public LayoutParams(Context context, android.util.AttributeSet attrs) { super(context, attrs); }
    }

    ListAdapter adapter;
    private int choiceMode = CHOICE_MODE_NONE, checkedPosition = INVALID_POSITION;
    private final List<Integer> checkedPositions = new ArrayList<>();
    private final android.database.DataSetObserver observer = new android.database.DataSetObserver() {
        @Override public void onChanged() { tvboxRows(); }
        @Override public void onInvalidated() { tvboxRows(); }
    };

    public AbsListView(Context context) { super(context); }
    public AbsListView(Context context, android.util.AttributeSet attrs) { super(context); }
    public AbsListView(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }

    @Override public ListAdapter getAdapter() { return adapter; }
    @Override public void setAdapter(ListAdapter value) {
        if (adapter != null) adapter.unregisterDataSetObserver(observer);
        adapter = value;
        if (adapter != null) adapter.registerDataSetObserver(observer);
        checkedPositions.clear(); checkedPosition = INVALID_POSITION;
        tvboxRows();
    }
    @Override public View getSelectedView() { return getChildAt(selectedPosition); }
    @Override public void setSelection(int position) { if (position >= 0 && position < getCount()) selectedPosition = position; }
    public void smoothScrollToPosition(int position) { }
    public void smoothScrollToPositionFromTop(int position, int offset) { }
    public void setSelectionFromTop(int position, int y) { setSelection(position); }
    public void setChoiceMode(int value) { choiceMode = value; }
    public int getChoiceMode() { return choiceMode; }
    public void setItemChecked(int position, boolean value) {
        if (position < 0) return;
        if (choiceMode == CHOICE_MODE_SINGLE) { if (value) checkedPosition = position; else if (checkedPosition == position) checkedPosition = INVALID_POSITION; }
        else if (choiceMode != CHOICE_MODE_NONE) { checkedPositions.remove((Integer) position); if (value) checkedPositions.add(position); }
        markRows();
    }
    public boolean isItemChecked(int position) { return choiceMode == CHOICE_MODE_SINGLE ? checkedPosition == position : checkedPositions.contains(position); }
    public int getCheckedItemPosition() { return choiceMode == CHOICE_MODE_SINGLE ? checkedPosition : INVALID_POSITION; }
    public int getCheckedItemCount() { return choiceMode == CHOICE_MODE_SINGLE ? (checkedPosition >= 0 ? 1 : 0) : checkedPositions.size(); }
    public long[] getCheckedItemIds() { return checkedPositions.stream().mapToLong(this::getItemIdAtPosition).toArray(); }
    public void clearChoices() { checkedPosition = INVALID_POSITION; checkedPositions.clear(); markRows(); }
    public void setOnScrollListener(OnScrollListener listener) { }
    public void setSelector(android.graphics.drawable.Drawable selector) { }
    public void setSelector(int resid) { }
    public void setDrawSelectorOnTop(boolean value) { }
    public void setCacheColorHint(int color) { }
    public void setFastScrollEnabled(boolean value) { }
    public void setFastScrollAlwaysVisible(boolean value) { }
    public void setScrollingCacheEnabled(boolean value) { }
    public void setSmoothScrollbarEnabled(boolean value) { }
    public void setStackFromBottom(boolean value) { }
    public void setTranscriptMode(int mode) { }
    public void setTextFilterEnabled(boolean value) { }
    public void setNestedScrollingEnabled(boolean value) { }
    public void invalidateViews() { tvboxRows(); }
    @Override public void requestLayout() { }

    /** Builds the rows from the adapter again, reusing the old row views as convertViews. */
    public void tvboxRows() {
        int count = adapter == null ? 0 : adapter.getCount();
        List<View> old = new ArrayList<>();
        for (int i = 0; i < getChildCount(); i++) old.add(getChildAt(i));
        List<View> rows = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            View row = adapter.getView(i, i < old.size() ? old.get(i) : null, this);
            if (row == null) row = new TextView(getContext());
            final int position = i;
            final View tapped = row;
            row.tvboxItemTap = () -> tvboxItemClicked(tapped, position);
            rows.add(row);
        }
        if (!rows.equals(old)) {
            removeAllViews();
            for (View row : rows) { if (row.getParent() instanceof ViewGroup parent) parent.removeView(row); addView(row); }
        }
        markRows();
    }
    private void markRows() {
        if (choiceMode == CHOICE_MODE_NONE) return;
        for (int i = 0; i < getChildCount(); i++) {
            View row = getChildAt(i);
            boolean on = isItemChecked(i);
            row.setActivated(on);
            if (row instanceof Checkable checkable) checkable.setChecked(on);
        }
    }
    /** A row tapped: it becomes checked in a choice list, then the item click listener runs, as on Android. */
    void tvboxItemClicked(View row, int position) {
        if (choiceMode == CHOICE_MODE_SINGLE) setItemChecked(position, true);
        else if (choiceMode != CHOICE_MODE_NONE) setItemChecked(position, !isItemChecked(position));
        selected(position);
        performItemClick(row, position, getItemIdAtPosition(position));
    }
    @Override protected String tvboxAxis() { return "v"; }
    @Override protected void tvboxDescribe(org.json.JSONObject node) throws org.json.JSONException {
        if (adapter != null && getChildCount() != adapter.getCount()) tvboxRows();
        super.tvboxDescribe(node);
    }
}
