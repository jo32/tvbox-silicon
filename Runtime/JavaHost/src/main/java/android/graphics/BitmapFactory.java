package android.graphics;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.util.zip.DataFormatException;
import java.util.zip.Inflater;

/**
 * Decodes PNG images (the format plugins draw QR codes and icons in) without java.desktop, which the
 * Apple runtimes leave out. Like Android, anything it cannot decode (JPEG, WebP, GIF, broken data) gives null.
 */
public class BitmapFactory {
    public static class Options {
        public boolean inJustDecodeBounds, inMutable, inScaled = true, inDither, inPurgeable, inInputShareable, inPreferQualityOverSpeed;
        public int inSampleSize = 1, inDensity, inTargetDensity, inScreenDensity;
        public Bitmap.Config inPreferredConfig = Bitmap.Config.ARGB_8888;
        public Bitmap inBitmap;
        public byte[] inTempStorage;
        public int outWidth = -1, outHeight = -1;
        public String outMimeType;
        public Bitmap.Config outConfig;
        public Options() { }
        public void requestCancelDecode() { }
    }

    public static Bitmap decodeByteArray(byte[] data, int offset, int length) { return decodeByteArray(data, offset, length, null); }
    public static Bitmap decodeByteArray(byte[] data, int offset, int length, Options options) {
        if (data == null || offset < 0 || length < 0 || offset + length > data.length) throw new ArrayIndexOutOfBoundsException();
        byte[] bytes = offset == 0 && length == data.length ? data : java.util.Arrays.copyOfRange(data, offset, offset + length);
        try { return png(bytes, options); } catch (RuntimeException | DataFormatException broken) { return null; }
    }
    public static Bitmap decodeStream(InputStream stream) { return decodeStream(stream, null, null); }
    public static Bitmap decodeStream(InputStream stream, Rect padding, Options options) {
        if (stream == null) return null;
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            stream.transferTo(out);
            byte[] bytes = out.toByteArray();
            return decodeByteArray(bytes, 0, bytes.length, options);
        } catch (IOException failed) { return null; }
    }
    public static Bitmap decodeFile(String path) { return decodeFile(path, null); }
    public static Bitmap decodeFile(String path, Options options) {
        try { byte[] bytes = Files.readAllBytes(new File(path).toPath()); return decodeByteArray(bytes, 0, bytes.length, options); }
        catch (IOException | RuntimeException failed) { return null; }
    }
    public static Bitmap decodeResource(android.content.res.Resources resources, int id) { return null; }
    public static Bitmap decodeResource(android.content.res.Resources resources, int id, Options options) { return null; }
    public static Bitmap decodeFileDescriptor(java.io.FileDescriptor fd) { return null; }

    private static int u32(byte[] b, int at) { return (b[at] & 255) << 24 | (b[at + 1] & 255) << 16 | (b[at + 2] & 255) << 8 | (b[at + 3] & 255); }

    private static Bitmap png(byte[] b, Options options) throws DataFormatException {
        byte[] signature = {(byte) 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
        if (b.length < 8) return null;
        for (int i = 0; i < 8; i++) if (b[i] != signature[i]) return null;
        int width = 0, height = 0, depth = 0, type = 0, interlace = 0;
        byte[] palette = null, transparency = null;
        ByteArrayOutputStream compressed = new ByteArrayOutputStream();
        int at = 8;
        while (at + 8 <= b.length) {
            int length = u32(b, at);
            String chunk = new String(b, at + 4, 4, java.nio.charset.StandardCharsets.US_ASCII);
            int data = at + 8;
            if (length < 0 || data + length > b.length) return null;
            switch (chunk) {
                case "IHDR" -> { width = u32(b, data); height = u32(b, data + 4); depth = b[data + 8] & 255; type = b[data + 9] & 255; interlace = b[data + 12] & 255; }
                case "PLTE" -> palette = java.util.Arrays.copyOfRange(b, data, data + length);
                case "tRNS" -> transparency = java.util.Arrays.copyOfRange(b, data, data + length);
                case "IDAT" -> compressed.write(b, data, length);
                default -> { }
            }
            if (chunk.equals("IEND")) break;
            at = data + length + 4;
        }
        if (width <= 0 || height <= 0 || interlace != 0) return null;
        int channels = switch (type) { case 0 -> 1; case 2 -> 3; case 3 -> 1; case 4 -> 2; case 6 -> 4; default -> -1; };
        if (channels < 0 || (depth != 8 && depth != 16 && !(depth < 8 && (type == 0 || type == 3)))) return null;
        if (options != null) { options.outWidth = width; options.outHeight = height; options.outMimeType = "image/png"; options.outConfig = Bitmap.Config.ARGB_8888; }
        if (options != null && options.inJustDecodeBounds) return null;
        int bitsPerPixel = channels * depth, stride = (width * bitsPerPixel + 7) / 8, bpp = Math.max(1, bitsPerPixel / 8);
        byte[] raw = new byte[(stride + 1) * height];
        Inflater inflater = new Inflater();
        inflater.setInput(compressed.toByteArray());
        int filled = 0;
        while (filled < raw.length && !inflater.finished()) {
            int n = inflater.inflate(raw, filled, raw.length - filled);
            if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break;
            filled += n;
        }
        inflater.end();
        if (filled < raw.length) return null;
        int[] pixels = new int[width * height];
        byte[] previous = new byte[stride], row = new byte[stride];
        for (int y = 0; y < height; y++) {
            int base = y * (stride + 1), filter = raw[base] & 255;
            for (int i = 0; i < stride; i++) {
                int x = raw[base + 1 + i] & 255, a = i >= bpp ? row[i - bpp] & 255 : 0, up = previous[i] & 255, c = i >= bpp ? previous[i - bpp] & 255 : 0;
                int value = switch (filter) {
                    case 1 -> x + a;
                    case 2 -> x + up;
                    case 3 -> x + ((a + up) >> 1);
                    case 4 -> { int p = a + up - c, pa = Math.abs(p - a), pb = Math.abs(p - up), pc = Math.abs(p - c); yield x + (pa <= pb && pa <= pc ? a : pb <= pc ? up : c); }
                    default -> x;
                };
                row[i] = (byte) value;
            }
            for (int x = 0; x < width; x++) pixels[y * width + x] = pixel(row, x, type, depth, palette, transparency);
            byte[] swap = previous; previous = row; row = swap;
        }
        int sample = options == null ? 1 : Math.max(1, Integer.highestOneBit(Math.max(1, options.inSampleSize)));
        if (sample > 1) {
            int w = Math.max(1, width / sample), h = Math.max(1, height / sample);
            int[] smaller = new int[w * h];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) smaller[y * w + x] = pixels[(y * sample) * width + x * sample];
            return Bitmap.createBitmap(smaller, w, h, Bitmap.Config.ARGB_8888);
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888);
    }

    private static int sample(byte[] row, int index, int depth) {
        if (depth == 8) return row[index] & 255;
        if (depth == 16) return row[index * 2] & 255; // the high byte
        int perByte = 8 / depth, shift = 8 - depth * (index % perByte + 1);
        return (row[index / perByte] >> shift) & ((1 << depth) - 1);
    }
    private static int pixel(byte[] row, int x, int type, int depth, byte[] palette, byte[] trns) {
        switch (type) {
            case 0 -> {
                int raw = sample(row, x, depth), gray = depth < 8 ? raw * 255 / ((1 << depth) - 1) : raw;
                boolean clear = trns != null && trns.length >= 2 && raw == (depth == 16 ? trns[0] & 255 : ((trns[0] & 255) << 8 | trns[1] & 255));
                int alpha = clear ? 0 : 255;
                return Color.argb(alpha, gray, gray, gray);
            }
            case 2 -> {
                int r = sample(row, x * 3, depth), g = sample(row, x * 3 + 1, depth), bl = sample(row, x * 3 + 2, depth);
                return Color.argb(255, r, g, bl);
            }
            case 3 -> {
                int index = sample(row, x, depth);
                if (palette == null || index * 3 + 2 >= palette.length) return 0;
                int alpha = trns != null && index < trns.length ? trns[index] & 255 : 255;
                return Color.argb(alpha, palette[index * 3] & 255, palette[index * 3 + 1] & 255, palette[index * 3 + 2] & 255);
            }
            case 4 -> { int g = sample(row, x * 2, depth); return Color.argb(sample(row, x * 2 + 1, depth), g, g, g); }
            default -> { return Color.argb(sample(row, x * 4 + 3, depth), sample(row, x * 4, depth), sample(row, x * 4 + 1, depth), sample(row, x * 4 + 2, depth)); }
        }
    }
}
