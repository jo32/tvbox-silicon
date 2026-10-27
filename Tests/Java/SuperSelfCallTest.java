import dalvik.system.DexClassLoader;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import org.jf.dexlib2.*;
import org.jf.dexlib2.iface.instruction.Instruction;
import org.jf.dexlib2.immutable.*;
import org.jf.dexlib2.immutable.instruction.*;
import org.jf.dexlib2.immutable.reference.*;
import org.jf.dexlib2.writer.io.MemoryDataStore;
import org.jf.dexlib2.writer.pool.DexPool;

/**
 * Dex's invoke-super may name the calling class itself (`invoke-super {p0, p1, p2}, Pan;->init(...)` in Pan,
 * from the qist/tvbox xiaosa jar). ART starts the lookup at the superclass, but the JVM's invokespecial on the
 * class's own method calls that method again: every Pan source died with StackOverflowError in Pan.init.
 */
public final class SuperSelfCallTest {
    static final String BASE = "Ltvbox/SuperSelfBase;", PROBE = "Ltvbox/SuperSelfProbe;";
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    static ImmutableMethod method(String owner, String name, int access, int registers, Instruction... code) {
        return new ImmutableMethod(owner, name, List.of(), name.equals("<init>") ? "V" : "Ljava/lang/String;", access, Set.of(), Set.of(),
            new ImmutableMethodImplementation(registers, List.of(code), null, null));
    }

    static ImmutableMethod constructor(String owner, String parent) {
        return method(owner, "<init>", AccessFlags.PUBLIC.getValue() | AccessFlags.CONSTRUCTOR.getValue(), 1,
            new ImmutableInstruction35c(Opcode.INVOKE_DIRECT, 1, 0, 0, 0, 0, 0, new ImmutableMethodReference(parent, "<init>", List.of(), "V")),
            new ImmutableInstruction10x(Opcode.RETURN_VOID));
    }

    static ImmutableMethod constant(String owner, String name, int access, String text) {
        return method(owner, name, access, 2,
            new ImmutableInstruction21c(Opcode.CONST_STRING, 0, new ImmutableStringReference(text)),
            new ImmutableInstruction11x(Opcode.RETURN_OBJECT, 0));
    }

    /** v0 = result, v1 = this. */
    static ImmutableMethod calling(String name, Opcode opcode, String target) {
        return method(PROBE, name, AccessFlags.PUBLIC.getValue(), 2,
            new ImmutableInstruction35c(opcode, 1, 1, 0, 0, 0, 0, new ImmutableMethodReference(PROBE, target, List.of(), "Ljava/lang/String;")),
            new ImmutableInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0),
            new ImmutableInstruction11x(Opcode.RETURN_OBJECT, 0));
    }

    static byte[] probeDex() throws Exception {
        int open = AccessFlags.PUBLIC.getValue();
        var pool = new DexPool(Opcodes.getDefault());
        pool.internClass(new ImmutableClassDef(BASE, open, "Ljava/lang/Object;", List.of(), null, Set.of(), List.of(),
            List.of(constructor(BASE, "Ljava/lang/Object;"), constant(BASE, "name", open, "base"))));
        pool.internClass(new ImmutableClassDef(PROBE, open, BASE, List.of(), null, Set.of(), List.of(), List.of(
            constructor(PROBE, BASE),
            // name() overrides Base.name() and calls super through its own class, as R8 writes it.
            calling("name", Opcode.INVOKE_SUPER, "name"),
            // A private method of the class itself is still called directly.
            constant(PROBE, "own", AccessFlags.PRIVATE.getValue(), "own"),
            calling("direct", Opcode.INVOKE_DIRECT, "own"))));
        var store = new MemoryDataStore();
        pool.writeTo(store);
        return Arrays.copyOf(store.getBuffer(), store.getSize());
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("super-self-call-test");
        try {
            Path jar = root.resolve("probe.jar");
            try (var zip = new ZipOutputStream(Files.newOutputStream(jar))) {
                zip.putNextEntry(new ZipEntry("classes.dex"));
                zip.write(probeDex());
            }
            try (var loader = new DexClassLoader(jar.toString(), root.toString(), "", SuperSelfCallTest.class.getClassLoader())) {
                Class<?> probe = Class.forName("tvbox.SuperSelfProbe", true, loader);
                Object instance = probe.getDeclaredConstructor().newInstance();
                Object name;
                try { name = probe.getMethod("name").invoke(instance); }
                catch (java.lang.reflect.InvocationTargetException e) { throw new AssertionError("super call through the own class failed: " + e.getCause()); }
                check("base".equals(name), "super call through the own class returned " + name);
                check("own".equals(probe.getMethod("direct").invoke(instance)), "private call no longer reaches the class's own method");
            }
        } finally {
            try (var files = Files.walk(root)) { for (Path p : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); }
        }
        System.out.println("SuperSelfCallTest passed: invoke-super naming its own class reaches the superclass");
    }
}
