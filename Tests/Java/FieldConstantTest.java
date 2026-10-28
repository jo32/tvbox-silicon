import dalvik.system.DexClassLoader;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import org.jf.dexlib2.*;
import org.jf.dexlib2.iface.value.EncodedValue;
import org.jf.dexlib2.immutable.*;
import org.jf.dexlib2.immutable.instruction.*;
import org.jf.dexlib2.immutable.reference.*;
import org.jf.dexlib2.immutable.value.*;
import org.jf.dexlib2.writer.io.MemoryDataStore;
import org.jf.dexlib2.writer.pool.DexPool;

/**
 * Dex gives any static field an initial value, a class file only primitives and Strings in String fields.
 * dex2jar copied a String kept in an Object field (or a class in a Class field) into the field's
 * ConstantValue, and the JVM refused the whole class: "Bad string initial value in class file
 * com/github/catvod/spider/Init", which took every source of that jar down. ART also keeps a String in a field of
 * another type (a HashMap); setting that in <clinit> failed with "Bad type on operand stack" (ed372dc7299b).
 */
public final class FieldConstantTest {
    static final String PROBE = "Ltvbox/FieldConstantProbe;";
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    static ImmutableField field(String name, String type, EncodedValue value) {
        return new ImmutableField(PROBE, name, type, AccessFlags.PUBLIC.getValue() | AccessFlags.STATIC.getValue() | AccessFlags.FINAL.getValue(), value, Set.of(), null);
    }

    /** Static values only, and optionally a <clinit> that sets one more field (the static values come first). */
    static byte[] probeDex(boolean withInitializer) throws Exception {
        var fields = new ArrayList<ImmutableField>(List.of(
            field("text", "Ljava/lang/Object;", new ImmutableStringEncodedValue("spider")),
            field("sequence", "Ljava/lang/CharSequence;", new ImmutableStringEncodedValue("sequence")),
            field("type", "Ljava/lang/Class;", new ImmutableTypeEncodedValue("Ljava/lang/String;")),
            field("plain", "Ljava/lang/String;", new ImmutableStringEncodedValue("plain")),
            field("number", "I", new ImmutableIntEncodedValue(7)),
            field("map", "Ljava/util/HashMap;", new ImmutableStringEncodedValue("map")),
            field("list", "Ljava/util/List;", new ImmutableTypeEncodedValue("Ljava/lang/String;"))));
        var methods = new ArrayList<ImmutableMethod>();
        if (withInitializer) {
            fields.add(new ImmutableField(PROBE, "copy", "Ljava/lang/Object;", AccessFlags.PUBLIC.getValue() | AccessFlags.STATIC.getValue(), null, Set.of(), null));
            var text = new ImmutableFieldReference(PROBE, "text", "Ljava/lang/Object;");
            var copy = new ImmutableFieldReference(PROBE, "copy", "Ljava/lang/Object;");
            methods.add(new ImmutableMethod(PROBE, "<clinit>", List.of(), "V", AccessFlags.STATIC.getValue() | AccessFlags.CONSTRUCTOR.getValue(), Set.of(), Set.of(),
                new ImmutableMethodImplementation(1, List.of(
                    new ImmutableInstruction21c(Opcode.SGET_OBJECT, 0, text),
                    new ImmutableInstruction21c(Opcode.SPUT_OBJECT, 0, copy),
                    new ImmutableInstruction10x(Opcode.RETURN_VOID)), null, null)));
        }
        var pool = new DexPool(Opcodes.getDefault());
        pool.internClass(new ImmutableClassDef(PROBE, AccessFlags.PUBLIC.getValue(), "Ljava/lang/Object;", List.of(), null, Set.of(), fields, methods));
        var store = new MemoryDataStore();
        pool.writeTo(store);
        return Arrays.copyOf(store.getBuffer(), store.getSize());
    }

    static void load(boolean withInitializer) throws Exception {
        Path root = Files.createTempDirectory("field-constant-test");
        try {
            Path jar = root.resolve("probe.jar");
            try (var zip = new ZipOutputStream(Files.newOutputStream(jar))) {
                zip.putNextEntry(new ZipEntry("classes.dex"));
                zip.write(probeDex(withInitializer));
            }
            try (var loader = new DexClassLoader(jar.toString(), root.toString(), "", FieldConstantTest.class.getClassLoader())) {
                Class<?> probe = Class.forName("tvbox.FieldConstantProbe", true, loader);
                check("spider".equals(probe.getField("text").get(null)), "String in an Object field lost");
                check("sequence".equals(probe.getField("sequence").get(null)), "String in a CharSequence field lost");
                check(probe.getField("type").get(null) == String.class, "Class constant lost");
                check("plain".equals(probe.getField("plain").get(null)), "String constant lost");
                check(Integer.valueOf(7).equals(probe.getField("number").get(null)), "int constant lost");
                check(probe.getField("map").get(null) == null && probe.getField("list").get(null) == null, "value of another type kept");
                if (withInitializer) check("spider".equals(probe.getField("copy").get(null)), "<clinit> ran before the static values");
            }
        } finally {
            try (var files = Files.walk(root)) { for (Path p : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); }
        }
    }

    public static void main(String[] args) throws Exception {
        load(false);
        load(true);
        System.out.println("FieldConstantTest passed: static values of Object and Class fields survive conversion, others are left out");
    }
}
