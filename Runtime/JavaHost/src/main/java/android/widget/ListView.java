package android.widget;

import android.content.Context;
import android.view.View;
import java.util.ArrayList;
import java.util.List;

public class ListView extends AbsListView {
    private final List<View> headers = new ArrayList<>(), footers = new ArrayList<>();
    public ListView(Context context) { super(context); }
    public ListView(Context context, android.util.AttributeSet attrs) { super(context); }
    public ListView(Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context); }
    public void setDivider(android.graphics.drawable.Drawable divider) { }
    public android.graphics.drawable.Drawable getDivider() { return null; }
    public void setDividerHeight(int height) { }
    public int getDividerHeight() { return 0; }
    public void setItemsCanFocus(boolean value) { }
    public boolean getItemsCanFocus() { return false; }
    public void setHeaderDividersEnabled(boolean value) { }
    public void setFooterDividersEnabled(boolean value) { }
    public void addHeaderView(View view) { headers.add(view); }
    public void addHeaderView(View view, Object data, boolean selectable) { headers.add(view); }
    public void addFooterView(View view) { footers.add(view); }
    public void addFooterView(View view, Object data, boolean selectable) { footers.add(view); }
    public boolean removeHeaderView(View view) { return headers.remove(view); }
    public boolean removeFooterView(View view) { return footers.remove(view); }
    public int getHeaderViewsCount() { return headers.size(); }
    public int getFooterViewsCount() { return footers.size(); }
    public int getMaxScrollAmount() { return 0; }
    public void smoothScrollByOffset(int offset) { }
}
