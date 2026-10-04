package dalvik.system;
import com.googlecode.d2j.dex.Dex2jar;
import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.jar.JarFile;
/** Converts loaded DEX to JVM bytecode while retaining the plugin's own classes. */
public class DexClassLoader extends URLClassLoader {
    public static DexClassLoader current;
    public DexClassLoader(String path, String optimizedDirectory, String librarySearchPath, ClassLoader parent) throws Exception {
        super(new URL[]{convert(path, optimizedDirectory), new File(path).toURI().toURL()}, parent);
        current = this;
        System.err.println("DEX_LOADER_READY " + path);
    }
    private static synchronized URL convert(String path, String cache) throws Exception {
        byte[] data = Files.readAllBytes(new File(path).toPath());
        String hash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        File fallback = new File(System.getProperty("tvbox.cache", cache), "converted");
        Path folder = Path.of(System.getProperty("tvbox.converted", fallback.getPath()));
        Files.createDirectories(folder);
        // Both the DEX content and host transform version determine the artifact.
        // A process lock prevents concurrent searches from converting the same DEX.
        String key = hash + "." + tvbox.runtime.BytecodeCompatibility.VERSION;
        Path compatible = folder.resolve(key + ".jar");
        try (FileChannel channel = FileChannel.open(folder.resolve(key + ".lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             var lock = channel.lock()) {
            if (valid(compatible)) {
                System.err.println("DEX_CACHE_HIT " + key);
                return compatible.toUri().toURL();
            }
            Path original = Files.createTempFile(folder, "dex-", ".jar");
            Path rewritten = Files.createTempFile(folder, "rewritten-", ".jar");
            try {
                boolean jvmArchive = false;
                if (data.length > 2 && data[0] == 'P' && data[1] == 'K') {
                    try (var archive = new JarFile(path)) {
                        jvmArchive = archive.stream().noneMatch(e -> e.getName().matches("classes[0-9]*\\.dex"))
                            && archive.stream().anyMatch(e -> e.getName().endsWith(".class"));
                    }
                }
                if (jvmArchive) Files.write(original, data);
                else Dex2jar.from(com.googlecode.d2j.reader.MultiDexFileReader.open(data)).skipDebug(true).computeFrames(true).to(original);
                tvbox.runtime.BytecodeCompatibility.rewrite(original, rewritten);
                if (!valid(rewritten)) throw new java.io.IOException("Converted plugin contains no JVM classes");
                Files.move(rewritten, compatible, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                System.err.println("DEX_CACHE_CREATED " + key);
            } finally {
                Files.deleteIfExists(original);
                Files.deleteIfExists(rewritten);
            }
        }
        return compatible.toUri().toURL();
    }
    private static boolean valid(Path path) {
        if (!Files.isRegularFile(path)) return false;
        try (JarFile jar = new JarFile(path.toFile())) {
            return jar.stream().anyMatch(entry -> entry.getName().endsWith(".class"));
        } catch (java.io.IOException corrupt) { return false; }
    }
}
