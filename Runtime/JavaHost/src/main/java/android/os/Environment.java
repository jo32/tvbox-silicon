package android.os;

import java.io.File;

/** Android shared-storage calls are confined to this source's local profile. */
public final class Environment {
    public static final String MEDIA_MOUNTED = "mounted";
    public static final String DIRECTORY_DOWNLOADS = "Download";
    public static final String DIRECTORY_MOVIES = "Movies";
    public static final String DIRECTORY_MUSIC = "Music";
    public static final String DIRECTORY_PICTURES = "Pictures";

    public static File getExternalStorageDirectory() {
        var application = android.app.ActivityThread.currentApplication();
        File root = application == null
            ? new File(System.getProperty("tvbox.cache", System.getProperty("java.io.tmpdir")), "profile")
            : application.getFilesDir().getParentFile();
        File directory = new File(root, "external");
        directory.mkdirs();
        return directory;
    }

    public static File getExternalStoragePublicDirectory(String type) {
        File directory = new File(getExternalStorageDirectory(), type);
        directory.mkdirs();
        return directory;
    }
    public static String getExternalStorageState() { return MEDIA_MOUNTED; }
    public static String getExternalStorageState(File path) { return MEDIA_MOUNTED; }
    public static boolean isExternalStorageEmulated() { return true; }
    public static boolean isExternalStorageRemovable() { return false; }
}
