import tvbox.runtime.NativeLibraries;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import java.security.MessageDigest;

public final class NativeLibrariesTest {
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private static Path archive(Path directory, String name, byte[] bytes, String checksum) throws Exception {
        Path file = Files.createTempFile(directory, "guard-", ".jar");
        try (var zip = new ZipOutputStream(Files.newOutputStream(file))) {
            zip.putNextEntry(new ZipEntry("assets/" + name)); zip.write(bytes); zip.closeEntry();
            zip.putNextEntry(new ZipEntry("assets/" + name.replaceFirst("[-_]v8\\.so$", "") + ".md5"));
            zip.write(("arm64-v8a=" + checksum + "\narmeabi-v7a=ignored\n").getBytes()); zip.closeEntry();
        }
        return file;
    }
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("native-libraries-test");
        try {
            byte[] elf = new byte[64]; elf[0]=127; elf[1]='E'; elf[2]='L'; elf[3]='F'; elf[4]=2; elf[5]=1; elf[18]=(byte)183;
            String md5 = HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(elf));
            for (String name : List.of("FishGuard-v8.so", "ftyguard_v8.so", "future-v8.so")) {
                Path jar = archive(root, name, elf, md5);
                Path destination = Files.createTempDirectory(root, "extracted-");
                var prepared = NativeLibraries.prepareGuards(jar.toFile(), destination);
                check(prepared.size() == 1 && Arrays.equals(Files.readAllBytes(prepared.get(name)), elf), "Guard was not retained");
                String stem = name.replaceFirst("[-_]v8\\.so$", "");
                check(Files.exists(destination.resolve(stem + ".md5")), "Checksum sidecar missing");
                check(NativeLibraries.resolve(jar.toFile(), stem, destination).getFileName().toString().equals(name), "Guard lookup failed");
                try { NativeLibraries.resolve(jar.toFile(), "missing", destination); throw new AssertionError("Missing guard accepted"); }
                catch (NativeLibraries.UnsupportedLibrary expected) { check(expected.library.equals("missing"), "Missing library name lost"); }
            }
            Path bad = archive(root, "FishGuard-v8.so", elf, "00000000000000000000000000000000");
            try { NativeLibraries.prepareGuards(bad.toFile(), root.resolve("bad")); throw new AssertionError("Bad checksum accepted"); }
            catch (java.io.IOException expected) { check(expected.getMessage().contains("checksum mismatch"), "Wrong checksum error"); }
            elf[4] = 1;
            try { NativeLibraries.validateARM64(elf, "v7.so"); throw new AssertionError("32-bit ELF accepted"); }
            catch (NativeLibraries.UnsupportedLibrary expected) { check(expected.library.equals("v7.so"), "ABI error lost library"); }
            System.out.println("Native guard discovery, checksum, sidecar, lookup and ABI validation passed.");
        } finally {
            try (var paths = Files.walk(root)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path); }
        }
    }
}
