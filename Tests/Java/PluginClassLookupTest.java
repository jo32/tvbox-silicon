import dalvik.system.DexClassLoader;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import org.jf.dexlib2.*;
import org.jf.dexlib2.immutable.*;
import org.jf.dexlib2.immutable.instruction.*;
import org.jf.dexlib2.immutable.reference.*;
import org.jf.dexlib2.writer.io.MemoryDataStore;
import org.jf.dexlib2.writer.pool.DexPool;

/**
 * Native spider factories (the aowu plugin's DexNative.getSpider) name classes without a loader, and the
 * plugin opens a second DEX (tink-dex.jar) after its spiders. Looking only in the newest loader made every
 * later spider fail with "requires an Android native operation" until the app restarted.
 */
public final class PluginClassLookupTest {
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    /** One public class with a no-argument constructor, the shape native code creates with NewObject. */
    static Path archive(Path root, String name) throws Exception {
        String type = "L" + name.replace('.', '/') + ";";
        var objectInit = new ImmutableMethodReference("Ljava/lang/Object;", "<init>", List.of(), "V");
        var init = new ImmutableMethod(type, "<init>", List.of(), "V", AccessFlags.PUBLIC.getValue() | AccessFlags.CONSTRUCTOR.getValue(), Set.of(), Set.of(),
            new ImmutableMethodImplementation(1, List.of(
                new ImmutableInstruction35c(Opcode.INVOKE_DIRECT, 1, 0, 0, 0, 0, 0, objectInit),
                new ImmutableInstruction10x(Opcode.RETURN_VOID)), null, null));
        var pool = new DexPool(Opcodes.getDefault());
        pool.internClass(new ImmutableClassDef(type, AccessFlags.PUBLIC.getValue(), "Ljava/lang/Object;", List.of(), null, Set.of(), List.of(), List.of(init)));
        var store = new MemoryDataStore();
        pool.writeTo(store);
        Path jar = root.resolve(name + ".jar");
        try (var zip = new ZipOutputStream(Files.newOutputStream(jar))) {
            zip.putNextEntry(new ZipEntry("classes.dex"));
            zip.write(Arrays.copyOf(store.getBuffer(), store.getSize()));
        }
        return jar;
    }

    static void lookup(boolean lazy) throws Exception {
        System.setProperty("tvbox.lazyDex", Boolean.toString(lazy));
        Path root = Files.createTempDirectory("plugin-class-lookup");
        String spider = "tvbox.lookup" + lazy + ".Spider", helper = "tvbox.lookup" + lazy + ".Helper";
        try (var spiders = new DexClassLoader(archive(root, spider).toString(), root.toString(), "", PluginClassLookupTest.class.getClassLoader());
             var helpers = new DexClassLoader(archive(root, helper).toString(), root.toString(), "", PluginClassLookupTest.class.getClassLoader())) {
            check(DexClassLoader.current == helpers, "The second DEX should be the newest loader");
            Class<?> found = DexClassLoader.pluginClass(spider);
            check(found != null && found.getClassLoader() == spiders, "A class of the first DEX was lost once a second DEX opened (lazy=" + lazy + ")");
            check(found.getDeclaredConstructor().newInstance() != null, "The spider could not be created");
            check(DexClassLoader.pluginClass(spider) == found, "A second lookup defined the class again");
            check(DexClassLoader.pluginClass(helper).getClassLoader() == helpers, "The newest DEX's own class was not found");
            check(DexClassLoader.pluginClass("tvbox.lookup.Missing") == null, "A missing class must stay missing");
        } finally {
            System.clearProperty("tvbox.lazyDex");
            try (var files = Files.walk(root)) { for (Path p : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); }
        }
    }

    /**
     * The outer archive and the DEX it opens both define com.github.catvod.spider.Proxy. Guest code asks the
     * inner loader for it, then names it again; the name must keep meaning the class that loader handed out.
     */
    static void guestKeepsTheClassItWasGiven(boolean lazy) throws Exception {
        System.setProperty("tvbox.lazyDex", Boolean.toString(lazy));
        Path root = Files.createTempDirectory("guest-class");
        String proxy = "tvbox.guest" + lazy + ".Proxy";
        try (var outer = new DexClassLoader(archive(Files.createDirectories(root.resolve("outer")), proxy).toString(), root.toString(), "", PluginClassLookupTest.class.getClassLoader());
             var inner = new DexClassLoader(archive(Files.createDirectories(root.resolve("inner")), proxy).toString(), root.toString(), "", PluginClassLookupTest.class.getClassLoader())) {
            Class<?> stub = outer.loadClass(proxy);
            check(DexClassLoader.guestClass(proxy) == null, "Host code loading a class must not pin it for guest lookups");
            Class<?> real = com.github.unidbg.test.GuestLoadClass.load(inner, proxy);
            check(real.getClassLoader() == inner && real != stub, "The fixture should define two distinct classes");
            check(DexClassLoader.guestClass(proxy) == real, "The class the guest got from the inner loader was lost (lazy=" + lazy + ")");
            com.github.unidbg.test.GuestLoadClass.load(outer, proxy);
            check(DexClassLoader.guestClass(proxy) == stub, "The latest class handed to the guest wins");
        } finally {
            System.clearProperty("tvbox.lazyDex");
            try (var files = Files.walk(root)) { for (Path p : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); }
        }
    }

    public static void main(String[] args) throws Exception {
        lookup(false);
        lookup(true);
        guestKeepsTheClassItWasGiven(false);
        guestKeepsTheClassItWasGiven(true);
        System.out.println("PluginClassLookupTest passed: native class lookups see every plugin DEX and keep the class a loader gave the guest");
    }
}
