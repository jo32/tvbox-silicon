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
 * A 035 dex can hold interface methods with code: javac's default bridge for a covariant return
 * (`public synthetic bridge MessageLite getDefaultInstanceForType()` in protobuf's MessageOrBuilder, from the
 * 神仙 sx.jar). dex2jar writes such dex as Java 6 class files, which the JVM refuses with
 * "ClassFormatError: ... has illegal modifiers: 0x1041", and 华谊/苹果影视 (csp_AppDrama) never loaded.
 */
public final class InterfaceDefaultMethodTest {
    static final String FACE = "Ltvbox/DefaultFace;", IMPL = "Ltvbox/DefaultImpl;";
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    static ImmutableMethod method(String owner, String name, String returns, int access, int registers, Instruction... code) {
        return new ImmutableMethod(owner, name, List.of(), returns, access, Set.of(), Set.of(),
            code.length == 0 ? null : new ImmutableMethodImplementation(registers, List.of(code), null, null));
    }

    static byte[] probeDex() throws Exception {
        int open = AccessFlags.PUBLIC.getValue();
        var pool = new DexPool(Opcodes.forApi(23));
        pool.internClass(new ImmutableClassDef(FACE, open | AccessFlags.INTERFACE.getValue() | AccessFlags.ABSTRACT.getValue(), "Ljava/lang/Object;",
            List.of(), null, Set.of(), List.of(), List.of(
                method(FACE, "name", "Ljava/lang/String;", open | AccessFlags.ABSTRACT.getValue(), 0),
                // v0 = result, v1 = this: the bridge calls the covariant method, as javac writes it.
                method(FACE, "name", "Ljava/lang/Object;", open | AccessFlags.BRIDGE.getValue() | AccessFlags.SYNTHETIC.getValue(), 2,
                    new ImmutableInstruction35c(Opcode.INVOKE_INTERFACE, 1, 1, 0, 0, 0, 0, new ImmutableMethodReference(FACE, "name", List.of(), "Ljava/lang/String;")),
                    new ImmutableInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0),
                    new ImmutableInstruction11x(Opcode.RETURN_OBJECT, 0)))));
        pool.internClass(new ImmutableClassDef(IMPL, open, "Ljava/lang/Object;", List.of(FACE), null, Set.of(), List.of(), List.of(
            method(IMPL, "<init>", "V", open | AccessFlags.CONSTRUCTOR.getValue(), 1,
                new ImmutableInstruction35c(Opcode.INVOKE_DIRECT, 1, 0, 0, 0, 0, 0, new ImmutableMethodReference("Ljava/lang/Object;", "<init>", List.of(), "V")),
                new ImmutableInstruction10x(Opcode.RETURN_VOID)),
            method(IMPL, "name", "Ljava/lang/String;", open, 2,
                new ImmutableInstruction21c(Opcode.CONST_STRING, 0, new ImmutableStringReference("impl")),
                new ImmutableInstruction11x(Opcode.RETURN_OBJECT, 0)))));
        var store = new MemoryDataStore();
        pool.writeTo(store);
        byte[] dex = Arrays.copyOf(store.getBuffer(), store.getSize());
        check(new String(dex, 4, 3).equals("035"), "fixture is not a 035 dex");
        return dex;
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("interface-default-test");
        try {
            Path jar = root.resolve("probe.jar");
            try (var zip = new ZipOutputStream(Files.newOutputStream(jar))) {
                zip.putNextEntry(new ZipEntry("classes.dex"));
                zip.write(probeDex());
            }
            try (var loader = new DexClassLoader(jar.toString(), root.toString(), "", InterfaceDefaultMethodTest.class.getClassLoader())) {
                Class<?> face;
                try { face = Class.forName("tvbox.DefaultFace", true, loader); }
                catch (ClassFormatError refused) { throw new AssertionError("interface with a default method was refused: " + refused.getMessage()); }
                Object instance = Class.forName("tvbox.DefaultImpl", true, loader).getDeclaredConstructor().newInstance();
                var bridge = Arrays.stream(face.getMethods()).filter(m -> m.getName().equals("name") && m.getReturnType() == Object.class).findFirst().orElseThrow();
                check(bridge.isDefault(), "bridge is not a default method");
                check("impl".equals(bridge.invoke(instance)), "default bridge did not reach the implementation");
            }
        } finally {
            try (var files = Files.walk(root)) { for (Path p : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); }
        }
        System.out.println("InterfaceDefaultMethodTest passed: a 035 dex interface with a default bridge method loads and runs");
    }
}
