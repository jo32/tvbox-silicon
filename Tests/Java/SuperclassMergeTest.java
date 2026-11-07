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
 * Where a Child and its superclass Base meet (one register, two branches), the converted class's stack map frame
 * must say Base. dex2jar's getCommonSuperClass skipped the second type itself and answered Object in one of the
 * two orders, so the JVM rejected the class ("Type Object is not assignable to Base"): every 玩偶-style site of
 * FongMi's 前瞻版 JAR failed to load (#500).
 */
public final class SuperclassMergeTest {
    static final String BASE = "Ltvbox/MergeBase;", CHILD = "Ltvbox/MergeChild;", HOLDER = "Ltvbox/MergeHolder;", PROBE = "Ltvbox/MergeProbe;";
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    static ImmutableMethod constructor(String owner, String parent) {
        return new ImmutableMethod(owner, "<init>", List.of(), "V", AccessFlags.PUBLIC.getValue() | AccessFlags.CONSTRUCTOR.getValue(), Set.of(), Set.of(),
            new ImmutableMethodImplementation(1, List.of(
                new ImmutableInstruction35c(Opcode.INVOKE_DIRECT, 1, 0, 0, 0, 0, 0, new ImmutableMethodReference(parent, "<init>", List.of(), "V")),
                new ImmutableInstruction10x(Opcode.RETURN_VOID)), null, null));
    }

    /**
     * static Base name(Holder p0, boolean p1): v0 = p0.first; if (p1) v0 = p0.second; return v0. As in the
     * 前瞻版 JAR, the value reaching the join first is the one read before the branch.
     */
    static ImmutableMethod pick(String name, String first, String second) {
        var field = (java.util.function.Function<String, ImmutableFieldReference>) type -> new ImmutableFieldReference(HOLDER, type.equals(CHILD) ? "child" : "base", type);
        List<Instruction> code = List.of(
            new ImmutableInstruction22c(Opcode.IGET_OBJECT, 0, 1, field.apply(first)),  // 0: v0 = p0.first
            new ImmutableInstruction21t(Opcode.IF_EQZ, 2, 4),                           // 2: if !p1 goto 6
            new ImmutableInstruction22c(Opcode.IGET_OBJECT, 0, 1, field.apply(second)), // 4: v0 = p0.second
            new ImmutableInstruction11x(Opcode.RETURN_OBJECT, 0));                     // 6
        return new ImmutableMethod(PROBE, name, List.of(new ImmutableMethodParameter(HOLDER, Set.of(), null), new ImmutableMethodParameter("Z", Set.of(), null)), BASE,
            AccessFlags.PUBLIC.getValue() | AccessFlags.STATIC.getValue(), Set.of(), Set.of(), new ImmutableMethodImplementation(3, code, null, null));
    }

    static byte[] probeDex() throws Exception {
        int open = AccessFlags.PUBLIC.getValue();
        // DEX 039, as R8 writes today: its classes convert to Java 8 class files, which the JVM checks against
        // their stack map frames (older ones fall back to the inferring verifier, which hid the bug).
        var pool = new DexPool(Opcodes.forDexVersion(39));
        pool.internClass(new ImmutableClassDef(BASE, open, "Ljava/lang/Object;", List.of(), null, Set.of(), List.of(), List.of(constructor(BASE, "Ljava/lang/Object;"))));
        pool.internClass(new ImmutableClassDef(CHILD, open, BASE, List.of(), null, Set.of(), List.of(), List.of(constructor(CHILD, BASE))));
        pool.internClass(new ImmutableClassDef(HOLDER, open, "Ljava/lang/Object;", List.of(), null, Set.of(), List.of(
            new ImmutableField(HOLDER, "child", CHILD, open, null, Set.of(), null), new ImmutableField(HOLDER, "base", BASE, open, null, Set.of(), null)),
            List.of(constructor(HOLDER, "Ljava/lang/Object;"))));
        pool.internClass(new ImmutableClassDef(PROBE, open, "Ljava/lang/Object;", List.of(), null, Set.of(), List.of(), List.of(
            pick("childFirst", CHILD, BASE), pick("baseFirst", BASE, CHILD))));
        var store = new MemoryDataStore();
        pool.writeTo(store);
        return Arrays.copyOf(store.getBuffer(), store.getSize());
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("superclass-merge-test");
        try {
            Path jar = root.resolve("probe.jar");
            try (var zip = new ZipOutputStream(Files.newOutputStream(jar))) {
                zip.putNextEntry(new ZipEntry("classes.dex"));
                zip.write(probeDex());
            }
            try (var loader = new DexClassLoader(jar.toString(), root.toString(), "", SuperclassMergeTest.class.getClassLoader())) {
                Class<?> probe;
                try { probe = Class.forName("tvbox.MergeProbe", true, loader); }
                catch (VerifyError rejected) { throw new AssertionError("a class and its superclass merged to Object: " + rejected.getMessage()); }
                Object holder = Class.forName("tvbox.MergeHolder", true, loader).getDeclaredConstructor().newInstance();
                Object child = Class.forName("tvbox.MergeChild", true, loader).getDeclaredConstructor().newInstance();
                Object base = Class.forName("tvbox.MergeBase", true, loader).getDeclaredConstructor().newInstance();
                holder.getClass().getField("child").set(holder, child);
                holder.getClass().getField("base").set(holder, base);
                var childFirst = probe.getMethod("childFirst", holder.getClass(), boolean.class);
                var baseFirst = probe.getMethod("baseFirst", holder.getClass(), boolean.class);
                check(childFirst.invoke(null, holder, false) == child && childFirst.invoke(null, holder, true) == base, "childFirst picked the wrong value");
                check(baseFirst.invoke(null, holder, false) == base && baseFirst.invoke(null, holder, true) == child, "baseFirst picked the wrong value");
            }
            System.out.println("SuperclassMergeTest passed");
        } finally {
            try (var files = Files.walk(root)) { files.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete()); }
        }
    }
}
