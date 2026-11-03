package android.graphics;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.zip.CRC32;
import java.util.zip.DeflaterOutputStream;

/**
 * Pixels in memory, for plugins that draw small images such as a QR code or a config center's tile
 * icons and hand them on as data: URLs (#360). Colors are unpremultiplied ARGB, like getPixel's.
 */
public final class Bitmap {
    public enum Config { ALPHA_8, RGB_565, ARGB_4444, ARGB_8888, RGBA_F16, HARDWARE }
    public enum CompressFormat { JPEG, PNG, WEBP, WEBP_LOSSY, WEBP_LOSSLESS }

    private final int width, height;
    private final Config config;
    final int[] pixels;
    private boolean recycled;

    private Bitmap(int width, int height, Config config) {
        if (width <= 0 || height <= 0) throw new IllegalArgumentException("width and height must be > 0");
        if ((long) width * height > 64L * 1024 * 1024) throw new IllegalArgumentException("Bitmap too large: " + width + "x" + height);
        this.width = width; this.height = height; this.config = config == null ? Config.ARGB_8888 : config;
        pixels = new int[width * height];
    }

    public static Bitmap createBitmap(int width, int height, Config config) { return new Bitmap(width, height, config); }
    public static Bitmap createBitmap(int[] colors, int width, int height, Config config) { return createBitmap(colors, 0, width, width, height, config); }
    public static Bitmap createBitmap(int[] colors, int offset, int stride, int width, int height, Config config) {
        Bitmap bitmap = new Bitmap(width, height, config);
        bitmap.setPixels(colors, offset, stride, 0, 0, width, height);
        return bitmap;
    }

    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public Config getConfig() { return config; }
    public boolean hasAlpha() { return config != Config.RGB_565; }
    public int getRowBytes() { return width * 4; }
    public int getByteCount() { return width * height * 4; }
    public boolean isRecycled() { return recycled; }
    public void recycle() { recycled = true; }
    public boolean isMutable() { return true; }

    public int getPixel(int x, int y) { check(x, y); return pixels[y * width + x]; }
    public void setPixel(int x, int y, int color) { check(x, y); pixels[y * width + x] = color; }
    public void eraseColor(int color) { java.util.Arrays.fill(pixels, color); }
    public void getPixels(int[] out, int offset, int stride, int x, int y, int w, int h) {
        for (int row = 0; row < h; row++) System.arraycopy(pixels, (y + row) * width + x, out, offset + row * stride, w);
    }
    public void setPixels(int[] colors, int offset, int stride, int x, int y, int w, int h) {
        if (x < 0 || y < 0 || w < 0 || h < 0 || x + w > width || y + h > height) throw new IllegalArgumentException("x + width and y + height must be inside the bitmap");
        for (int row = 0; row < h; row++) System.arraycopy(colors, offset + row * stride, pixels, (y + row) * width + x, w);
    }
    private void check(int x, int y) {
        if (x < 0 || y < 0 || x >= width || y >= height) throw new IllegalArgumentException("x and y must be inside the bitmap");
    }

    /** Writes a PNG whatever format is asked for: image decoders read the bytes, not the data: URL's label. */
    public boolean compress(CompressFormat format, int quality, OutputStream stream) {
        if (recycled || stream == null) return false;
        try {
            stream.write(new byte[]{(byte) 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'});
            ByteArrayOutputStream header = new ByteArrayOutputStream();
            writeInt(header, width); writeInt(header, height);
            header.write(new byte[]{8, 6, 0, 0, 0}); // 8-bit RGBA, no interlace
            chunk(stream, "IHDR", header.toByteArray());
            ByteArrayOutputStream data = new ByteArrayOutputStream();
            try (DeflaterOutputStream deflated = new DeflaterOutputStream(data)) {
                byte[] row = new byte[1 + width * 4];
                for (int y = 0; y < height; y++) {
                    for (int x = 0; x < width; x++) {
                        int color = pixels[y * width + x], at = 1 + x * 4;
                        row[at] = (byte) (color >> 16); row[at + 1] = (byte) (color >> 8); row[at + 2] = (byte) color;
                        row[at + 3] = (byte) (hasAlpha() ? color >>> 24 : 255);
                    }
                    deflated.write(row);
                }
            }
            chunk(stream, "IDAT", data.toByteArray());
            chunk(stream, "IEND", new byte[0]);
            return true;
        } catch (IOException failed) {
            return false;
        }
    }
    private static void writeInt(OutputStream out, int value) throws IOException {
        out.write(value >>> 24); out.write(value >>> 16); out.write(value >>> 8); out.write(value);
    }
    private static void chunk(OutputStream out, String type, byte[] data) throws IOException {
        byte[] name = type.getBytes(StandardCharsets.US_ASCII);
        writeInt(out, data.length); out.write(name); out.write(data);
        CRC32 crc = new CRC32(); crc.update(name); crc.update(data);
        writeInt(out, (int) crc.getValue());
    }

    /** Paints one pixel over what is there (source over), skipping pixels outside the bitmap. */
    void blend(int x, int y, int color) {
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        int alpha = color >>> 24;
        if (alpha == 0) return;
        int at = y * width + x;
        if (alpha == 255) { pixels[at] = color; return; }
        int under = pixels[at], underAlpha = under >>> 24;
        int outAlpha = alpha + underAlpha * (255 - alpha) / 255;
        if (outAlpha == 0) { pixels[at] = 0; return; }
        int result = outAlpha << 24;
        for (int shift = 0; shift <= 16; shift += 8) {
            int top = (color >> shift) & 255, bottom = (under >> shift) & 255;
            result |= ((top * alpha + bottom * underAlpha * (255 - alpha) / 255) / outAlpha) << shift;
        }
        pixels[at] = result;
    }
}
