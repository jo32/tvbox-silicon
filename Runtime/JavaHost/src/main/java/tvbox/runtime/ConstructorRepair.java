package tvbox.runtime;

import org.objectweb.asm.*;
import org.objectweb.asm.commons.AnalyzerAdapter;
import org.objectweb.asm.tree.*;
import java.lang.reflect.Modifier;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

/**
 * R8 drops trivial constructors and initializes a new object with an ancestor's &lt;init&gt; directly,
 * e.g. {@code new X; invokespecial Object.<init>} or {@code new MyError; invokespecial
 * RuntimeException.<init>(String)}. ART accepts that; the JVM verifier rejects the whole class
 * ("Call to wrong &lt;init&gt; method"). Repairs:
 * <ul>
 * <li>Object.&lt;init&gt;: allocate the object without a constructor, which is all ART ran.</li>
 * <li>Any other ancestor: call X.&lt;init&gt; with the same descriptor instead, and give every class
 * whose superclass comes from the host (Android/JDK) forwarding constructors for the superclass
 * constructors it lacks, so that call reaches the ancestor ART ran.</li>
 * </ul>
 */
public final class ConstructorRepair {
    private ConstructorRepair() { }

    private static final String OBJECT = "java/lang/Object";

    public static Object allocate(Class<?> type) throws InstantiationException {
        return unsafe().allocateInstance(type);
    }

    private static sun.misc.Unsafe unsafe;
    private static sun.misc.Unsafe unsafe() {
        if (unsafe == null) {
            try {
                var field = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
                field.setAccessible(true);
                unsafe = (sun.misc.Unsafe) field.get(null);
            } catch (ReflectiveOperationException error) { throw new IllegalStateException(error); }
        }
        return unsafe;
    }

    static byte[] repair(byte[] bytes) {
        ClassReader reader = new ClassReader(bytes);
        if ((reader.readUnsignedShort(6)) < Opcodes.V1_5) return bytes;
        Scan scan = scan(reader);
        boolean isInterface = (reader.getAccess() & Opcodes.ACC_INTERFACE) != 0;
        List<String> forwarding = isInterface ? List.of() : forwardingConstructors(reader.getSuperName(), scan.constructors);
        if (!scan.foreignInit && forwarding.isEmpty()) return bytes;
        ClassNode node = new ClassNode();
        reader.accept(node, ClassReader.EXPAND_FRAMES);
        boolean changed = false;
        if (scan.foreignInit) {
            for (MethodNode method : node.methods) {
                if (method.instructions.size() == 0) continue;
                try { changed |= repair(node.name, node.superName, method); }
                catch (RuntimeException ignored) { /* Leave the method for the verifier to report. */ }
            }
        }
        for (String descriptor : forwarding) {
            node.methods.add(forward(node.superName, descriptor));
            changed = true;
        }
        if (!changed) return bytes;
        ClassWriter writer = new ClassWriter(0);
        node.accept(writer);
        return writer.toByteArray();
    }

    private record Scan(boolean foreignInit, Set<String> constructors) { }

    /** Finds &lt;init&gt; calls that may target an object of another type, and the declared constructors. */
    private static Scan scan(ClassReader reader) {
        boolean[] found = { false };
        Set<String> constructors = new HashSet<>();
        String self = reader.getClassName(), parent = reader.getSuperName();
        reader.accept(new ClassVisitor(Opcodes.ASM9) {
            @Override public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                boolean constructor = name.equals("<init>");
                if (constructor) constructors.add(descriptor);
                if (found[0]) return null;
                return new MethodVisitor(Opcodes.ASM9) {
                    final Set<String> created = new HashSet<>();
                    final List<String> owners = new ArrayList<>();
                    int delegations = constructor ? 1 : 0;
                    @Override public void visitTypeInsn(int opcode, String type) { if (opcode == Opcodes.NEW) created.add(type); }
                    @Override public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) {
                        if (opcode != Opcodes.INVOKESPECIAL || !name.equals("<init>")) return;
                        if (delegations > 0 && (owner.equals(parent) || owner.equals(self))) { delegations--; return; }
                        owners.add(owner);
                    }
                    @Override public void visitEnd() {
                        for (String owner : owners) if (created.size() > 1 || !created.contains(owner)) found[0] = true;
                    }
                };
            }
        }, ClassReader.SKIP_FRAMES | ClassReader.SKIP_DEBUG);
        return new Scan(found[0], constructors);
    }

    /** A plugin class as declared in its archive: superclass and non-private constructors. */
    public record Declared(String superName, Set<String> constructors) { }

    /** Looks up plugin classes (internal names) without loading them; null when unknown. */
    public interface Hierarchy { Declared find(String name); }

    private static final ThreadLocal<Hierarchy> hierarchy = new ThreadLocal<>();

    /** Runs a conversion step with the plugin's own class hierarchy available. */
    public static <T> T with(Hierarchy lookup, java.util.concurrent.Callable<T> body) throws Exception {
        Hierarchy previous = hierarchy.get();
        Hierarchy combined = previous == null ? lookup : name -> { Declared found = lookup.find(name); return found != null ? found : previous.find(name); };
        hierarchy.set(combined);
        try { return body.call(); }
        finally { if (previous == null) hierarchy.remove(); else hierarchy.set(previous); }
    }

    private static final Map<String, List<String>> hostConstructors = new ConcurrentHashMap<>();

    /**
     * Constructors reachable on a class: its own plus, through the forwarding constructors this
     * repair adds to every plugin class, those of all its ancestors.
     */
    private static Set<String> inheritable(String name, int depth) {
        if (name == null || depth > 64) return Set.of();
        if (name.equals(OBJECT)) return Set.of("()V");
        Hierarchy lookup = hierarchy.get();
        Declared declared = lookup == null ? null : lookup.find(name);
        if (declared != null) {
            Set<String> result = new LinkedHashSet<>(declared.constructors());
            result.addAll(inheritable(declared.superName(), depth + 1));
            return result;
        }
        return new LinkedHashSet<>(hostConstructors(name));
    }

    /** Ancestor constructors a plugin class lacks. */
    private static List<String> forwardingConstructors(String superName, Set<String> declared) {
        List<String> missing = new ArrayList<>();
        for (String descriptor : inheritable(superName, 0)) if (!declared.contains(descriptor)) missing.add(descriptor);
        return missing;
    }

    private static List<String> hostConstructors(String superName) {
        return hostConstructors.computeIfAbsent(superName, name -> {
            try {
                Class<?> type = Class.forName(name.replace('/', '.'), false, ConstructorRepair.class.getClassLoader());
                List<String> result = new ArrayList<>();
                for (var constructor : type.getDeclaredConstructors()) {
                    if (!Modifier.isPublic(constructor.getModifiers()) && !Modifier.isProtected(constructor.getModifiers())) continue;
                    result.add(Type.getConstructorDescriptor(constructor));
                }
                return result;
            } catch (ClassNotFoundException | LinkageError pluginClass) { return List.of(); }
        });
    }

    private static MethodNode forward(String superName, String descriptor) {
        MethodNode method = new MethodNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_SYNTHETIC, "<init>", descriptor, null, null);
        method.visitCode();
        method.visitVarInsn(Opcodes.ALOAD, 0);
        int local = 1;
        for (Type argument : Type.getArgumentTypes(descriptor)) {
            method.visitVarInsn(argument.getOpcode(Opcodes.ILOAD), local);
            local += argument.getSize();
        }
        method.visitMethodInsn(Opcodes.INVOKESPECIAL, superName, "<init>", descriptor, false);
        method.visitInsn(Opcodes.RETURN);
        method.visitMaxs(local, local);
        method.visitEnd();
        return method;
    }

    private static boolean repair(String self, String parent, MethodNode method) {
        List<TypeInsnNode> news = new ArrayList<>();
        List<MethodInsnNode> inits = new ArrayList<>();
        for (AbstractInsnNode insn : method.instructions) {
            if (insn.getOpcode() == Opcodes.NEW) news.add((TypeInsnNode) insn);
            else if (insn.getOpcode() == Opcodes.INVOKESPECIAL && ((MethodInsnNode) insn).name.equals("<init>")) inits.add((MethodInsnNode) insn);
        }
        if (news.isEmpty() && !method.name.equals("<init>")) return false;

        // Replay the method to learn which NEW each <init> call consumes.
        Set<Integer> allocate = new HashSet<>();
        Set<Integer> drop = new HashSet<>();
        Map<Integer, String> retarget = new HashMap<>();
        Map<Object, Integer> origin = new IdentityHashMap<>();
        int[] counters = { 0, 0 };
        method.accept(new AnalyzerAdapter(Opcodes.ASM9, self, method.access, method.name, method.desc, null) {
            @Override public void visitTypeInsn(int opcode, String type) {
                super.visitTypeInsn(opcode, type);
                if (opcode != Opcodes.NEW) return;
                int index = counters[0]++;
                for (var entry : uninitializedTypes.entrySet()) if (!origin.containsKey(entry.getKey()) && type.equals(entry.getValue())) origin.put(entry.getKey(), index);
                if (stack != null && !stack.isEmpty()) origin.put(stack.get(stack.size() - 1), index);
            }
            @Override public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) {
                if (opcode == Opcodes.INVOKESPECIAL && name.equals("<init>")) {
                    int index = counters[1]++;
                    int receiver = stack == null ? -1 : stack.size() - 1 - Arrays.stream(Type.getArgumentTypes(descriptor)).mapToInt(Type::getSize).sum();
                    if (receiver >= 0 && stack.get(receiver) == Opcodes.UNINITIALIZED_THIS && !owner.equals(self) && !owner.equals(parent)) {
                        // A constructor calling a grandparent's constructor: go through the parent.
                        retarget.put(index, parent);
                    }
                    Integer created = receiver < 0 ? null : origin.get(stack.get(receiver));
                    String type = created == null ? null : news.get(created).desc;
                    if (type != null && !type.equals(owner)) {
                        if (owner.equals(OBJECT)) { allocate.add(created); drop.add(index); }
                        else retarget.put(index, type);
                    }
                }
                super.visitMethodInsn(opcode, owner, name, descriptor, isInterface);
            }
        });
        if (allocate.isEmpty() && retarget.isEmpty()) return false;
        for (var entry : retarget.entrySet()) inits.get(entry.getKey()).owner = entry.getValue();
        if (allocate.isEmpty()) return true;

        // Frames name an uninitialized value by the label just before its NEW.
        Map<LabelNode, String> retyped = new IdentityHashMap<>();
        for (int created : allocate) {
            TypeInsnNode insn = news.get(created);
            for (AbstractInsnNode previous = insn.getPrevious(); previous != null && previous.getOpcode() < 0; previous = previous.getPrevious())
                if (previous instanceof LabelNode label) retyped.put(label, insn.desc);
        }
        for (AbstractInsnNode insn : method.instructions) {
            if (insn instanceof FrameNode frame) {
                retype(frame.local, retyped);
                retype(frame.stack, retyped);
            }
        }
        for (int created : allocate) {
            TypeInsnNode insn = news.get(created);
            InsnList replacement = new InsnList();
            replacement.add(new LdcInsnNode(Type.getObjectType(insn.desc)));
            replacement.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "tvbox/runtime/ConstructorRepair", "allocate", "(Ljava/lang/Class;)Ljava/lang/Object;", false));
            replacement.add(new TypeInsnNode(Opcodes.CHECKCAST, insn.desc));
            method.instructions.insert(insn, replacement);
            method.instructions.remove(insn);
        }
        for (int index : drop) method.instructions.set(inits.get(index), new InsnNode(Opcodes.POP));
        return true;
    }

    private static void retype(List<Object> values, Map<LabelNode, String> retyped) {
        if (values == null) return;
        for (int i = 0; i < values.size(); i++) {
            if (values.get(i) instanceof LabelNode label && retyped.containsKey(label)) values.set(i, retyped.get(label));
        }
    }
}
