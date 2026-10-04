package android.preference;
import android.content.*;
public final class PreferenceManager {
    public static SharedPreferences getDefaultSharedPreferences(Context context) { return context.getSharedPreferences(context.getPackageName()+"_preferences",0); }
}
