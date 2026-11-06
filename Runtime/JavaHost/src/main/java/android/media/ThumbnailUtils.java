package android.media;

/** Video frames cannot be read here; Android also returns null when it cannot make a thumbnail. */
public class ThumbnailUtils {
    public static final int OPTIONS_RECYCLE_INPUT = 2;
    public static android.graphics.Bitmap createVideoThumbnail(String filePath, int kind) { return null; }
    public static android.graphics.Bitmap extractThumbnail(android.graphics.Bitmap source, int width, int height) { return source; }
    public static android.graphics.Bitmap extractThumbnail(android.graphics.Bitmap source, int width, int height, int options) { return source; }
}
