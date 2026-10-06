package tvbox.runtime;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;

/** Finds Android ARM64 guards without assuming that every guard uses FTY's JNI contract. */
public final class NativeLibraries {
    private NativeLibraries() {}

    public static final class UnsupportedLibrary extends UnsupportedOperationException {
        public final String library;
        public UnsupportedLibrary(String library, String reason) {
            super(library + ": " + reason); this.library = library;
        }
    }

    public static Map<String, Path> prepareGuards(File archive, Path directory) throws Exception {
        Map<String, Path> libraries = new TreeMap<>();
        try (ZipFile zip = new ZipFile(archive)) {
            for (ZipEntry entry : Collections.list(zip.entries())) {
                String name = entry.getName();
                if (!name.matches("assets/[^/]+[-_]v8\\.so")) continue;
                String leaf = name.substring("assets/".length());
                libraries.put(leaf, extract(zip, entry, directory));
            }
        }
        return libraries;
    }

    public static Path resolve(File archive, String name, Path directory) throws Exception {
        if (!name.matches("[A-Za-z0-9_.-]+")) throw new UnsupportedLibrary(name, "Invalid library name");
        String base = name.endsWith(".so") ? name.substring(0, name.length() - 3) : name;
        try (ZipFile zip = new ZipFile(archive)) {
            for (String candidate : new String[]{"lib/arm64-v8a/lib" + base + ".so", "assets/lib" + base + ".so",
                    "assets/" + base + ".so", "assets/" + base + "-v8.so", "assets/" + base + "_v8.so"}) {
                ZipEntry entry = zip.getEntry(candidate);
                if (entry != null) return extract(zip, entry, directory);
            }
        }
        throw new UnsupportedLibrary(name, "Plugin archive has no ARM64 library");
    }

    private static Path extract(ZipFile zip, ZipEntry entry, Path directory) throws Exception {
        String leaf = Path.of(entry.getName()).getFileName().toString();
        byte[] bytes;
        try (InputStream stream = zip.getInputStream(entry)) { bytes = stream.readNBytes(16 * 1024 * 1024 + 1); }
        if (bytes.length > 16 * 1024 * 1024) throw new UnsupportedLibrary(leaf, "Library exceeds 16 MB");
        validateARM64(bytes, leaf);
        String stem = leaf.replaceFirst("[-_]v8\\.so$", "");
        ZipEntry checksum = zip.getEntry("assets/" + stem + ".md5");
        byte[] checksumBytes = null;
        if (checksum != null) {
            try (InputStream stream = zip.getInputStream(checksum)) { checksumBytes = stream.readNBytes(4097); }
            if (checksumBytes.length > 4096) throw new IOException("Oversized checksum file for " + leaf);
            Properties values = new Properties();
            values.load(new StringReader(new String(checksumBytes, StandardCharsets.UTF_8)));
            String expected = values.getProperty("arm64-v8a");
            if (expected != null) {
                String actual = HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(bytes));
                if (!actual.equalsIgnoreCase(expected.trim())) throw new IOException("Native library checksum mismatch: " + leaf);
            }
        }
        Files.createDirectories(directory);
        Path target = directory.resolve(leaf);
        Path temporary = Files.createTempFile(directory, "native-", ".tmp");
        try {
            Files.write(temporary, bytes);
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            if (checksumBytes != null) Files.write(directory.resolve(stem + ".md5"), checksumBytes);
        } finally { Files.deleteIfExists(temporary); }
        return target;
    }

    public static void validateARM64(byte[] bytes, String name) {
        if (bytes.length < 20 || bytes[0] != 127 || bytes[1] != 'E' || bytes[2] != 'L' || bytes[3] != 'F'
                || bytes[4] != 2 || bytes[5] != 1 || (bytes[18] & 255) != 183 || bytes[19] != 0) {
            throw new UnsupportedLibrary(name, "Expected a little-endian ARM64 ELF library");
        }
    }
}
