package tvbox.runtime;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipFile;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * Types a plugin's DEX references but never defines, such as the parts of a bundled QR-code
 * library its build stripped. ART fails only when such code actually runs; HotSpot verifies whole
 * classes up front, so one missing interface would make unrelated plugin classes unloadable.
 * Empty placeholders restore ART's behaviour: classes load, and only real use of the missing
 * type fails, at the point of use.
 */
public final class DanglingTypes {
    private enum Kind { CLASS, INTERFACE, THROWABLE }
    private final Map<String, Kind> types;

    private DanglingTypes(Map<String, Kind> types) { this.types = types; }

    public static DanglingTypes of(Path archive) {
        Set<String> referenced = new HashSet<>(), defined = new HashSet<>(), interfaces = new HashSet<>(), throwables = new HashSet<>();
        try {
            if (isZip(archive)) {
                try (ZipFile zip = new ZipFile(archive.toFile())) {
                    var entries = zip.entries();
                    while (entries.hasMoreElements()) {
                        var entry = entries.nextElement();
                        if (!entry.getName().matches("classes[0-9]*\\.dex")) continue;
                        try (var input = zip.getInputStream(entry)) { scan(input.readAllBytes(), referenced, defined, interfaces, throwables); }
                    }
                }
            } else scan(Files.readAllBytes(archive), referenced, defined, interfaces, throwables);
        } catch (IOException | RuntimeException unreadable) {
            return new DanglingTypes(Map.of());
        }
        Map<String, Kind> types = new HashMap<>();
        for (String descriptor : referenced) {
            if (defined.contains(descriptor) || !descriptor.startsWith("L") || !descriptor.endsWith(";")) continue;
            String name = descriptor.substring(1, descriptor.length() - 1).replace('/', '.');
            if (platform(name)) continue;
            types.put(name, interfaces.contains(descriptor) ? Kind.INTERFACE : throwables.contains(descriptor) ? Kind.THROWABLE : Kind.CLASS);
        }
        return new DanglingTypes(types);
    }

    /** Platform and host libraries are never synthesized: a gap there is a real missing feature. */
    private static boolean platform(String name) {
        for (String prefix : new String[]{"java.", "javax.", "jdk.", "sun.", "android.", "androidx.", "dalvik.", "kotlin.", "kotlinx.", "okhttp3.", "okio.", "org.json.", "com.google.gson.", "com.github.catvod.crawler."})
            if (name.startsWith(prefix)) return true;
        return false;
    }

    private static boolean isZip(Path archive) throws IOException {
        try (var input = Files.newInputStream(archive)) { byte[] head = input.readNBytes(2); return head.length == 2 && head[0] == 'P' && head[1] == 'K'; }
    }

    /**
     * Referenced and defined types of one DEX file. A type is an interface when a class implements
     * it or code calls it through invoke-interface, and a throwable when code catches it or throws
     * an instance it created; its own definition is what is missing.
     */
    private static void scan(byte[] dex, Set<String> referenced, Set<String> defined, Set<String> interfaces, Set<String> throwables) {
        var file = new org.jf.dexlib2.dexbacked.DexBackedDexFile(org.jf.dexlib2.Opcodes.getDefault(), dex);
        for (var type : file.getTypeReferences()) referenced.add(type.getType());
        for (var definition : file.getClasses()) {
            defined.add(definition.getType());
            interfaces.addAll(definition.getInterfaces());
            for (var method : definition.getMethods()) {
                var code = method.getImplementation();
                if (code == null) continue;
                for (var block : code.getTryBlocks())
                    for (var handler : block.getExceptionHandlers()) if (handler.getExceptionType() != null) throwables.add(handler.getExceptionType());
                Map<Integer, String> created = new HashMap<>();
                for (var instruction : code.getInstructions()) {
                    var opcode = instruction.getOpcode();
                    if (opcode == org.jf.dexlib2.Opcode.NEW_INSTANCE && instruction instanceof org.jf.dexlib2.iface.instruction.formats.Instruction21c made
                        && made.getReference() instanceof org.jf.dexlib2.iface.reference.TypeReference type) created.put(made.getRegisterA(), type.getType());
                    else if (opcode == org.jf.dexlib2.Opcode.THROW && instruction instanceof org.jf.dexlib2.iface.instruction.formats.Instruction11x thrown
                        && created.containsKey(thrown.getRegisterA())) throwables.add(created.get(thrown.getRegisterA()));
                    if ((opcode == org.jf.dexlib2.Opcode.INVOKE_INTERFACE || opcode == org.jf.dexlib2.Opcode.INVOKE_INTERFACE_RANGE)
                        && instruction instanceof org.jf.dexlib2.iface.instruction.ReferenceInstruction call
                        && call.getReference() instanceof org.jf.dexlib2.iface.reference.MethodReference target)
                        interfaces.add(target.getDefiningClass());
                }
            }
        }
    }

    public boolean contains(String name) { return types.containsKey(name); }

    /** An empty interface, a RuntimeException, or a public class with a no-argument constructor. */
    public byte[] placeholder(String name) {
        Kind kind = types.getOrDefault(name, Kind.CLASS);
        String internal = name.replace('.', '/');
        String parent = kind == Kind.THROWABLE ? "java/lang/RuntimeException" : "java/lang/Object";
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC | (kind == Kind.INTERFACE ? Opcodes.ACC_INTERFACE | Opcodes.ACC_ABSTRACT : Opcodes.ACC_SUPER), internal, null, parent, null);
        if (kind != Kind.INTERFACE) {
            for (String descriptor : kind == Kind.THROWABLE ? new String[]{"()V", "(Ljava/lang/String;)V", "(Ljava/lang/String;Ljava/lang/Throwable;)V", "(Ljava/lang/Throwable;)V"} : new String[]{"()V"}) {
                MethodVisitor init = writer.visitMethod(Opcodes.ACC_PUBLIC, "<init>", descriptor, null, null);
                init.visitCode();
                init.visitVarInsn(Opcodes.ALOAD, 0);
                int slot = 1;
                for (var argument : org.objectweb.asm.Type.getArgumentTypes(descriptor)) init.visitVarInsn(Opcodes.ALOAD, slot++);
                init.visitMethodInsn(Opcodes.INVOKESPECIAL, parent, "<init>", descriptor, false);
                init.visitInsn(Opcodes.RETURN);
                init.visitMaxs(0, 0);
                init.visitEnd();
            }
        }
        writer.visitEnd();
        return writer.toByteArray();
    }
}
