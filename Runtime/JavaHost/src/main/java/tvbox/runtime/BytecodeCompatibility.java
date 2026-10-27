package tvbox.runtime;

import org.objectweb.asm.*;
import java.io.*;
import java.nio.file.*;
import java.util.zip.*;

/** Repairs JVM interface references emitted by the DEX converter and observes plugin HTTP calls. */
public final class BytecodeCompatibility {
    // v11: frames no longer reference the nonexistent java/util/Object; re-convert cached classes.
    // v12: objects that R8 initializes through Object.<init> are allocated directly.
    // v13: HttpURLConnection range requests are observed too (cloud-drive CDN addresses).
    // v14: large constant arrays (fill-array-data) are copied into the array, not out of it (IR2JConverter).
    // v16: static values a class file can't keep as constants (a String in an Object field) are set in <clinit>.
    // v17: invoke-super naming the calling class itself goes to the superclass, as on ART.
    public static final String VERSION = "host-v17";
    private static final java.util.Set<String> connections = java.util.Set.of("java/net/URLConnection", "java/net/HttpURLConnection", "javax/net/ssl/HttpsURLConnection");

    private static final String BRIDGES = "tvbox/runtime/generated/InterfaceCalls";
    private record CallSite(String owner, String name, String descriptor) { }
    private record InitialValue(String name, String descriptor, Object value) { }

    private static byte[] transform(byte[] bytes, java.util.Map<CallSite, String> bridges, String bridgeOwner) {
        bytes = ConstructorRepair.repair(bytes);
        ClassReader reader = new ClassReader(bytes);
        ClassWriter writer = new ClassWriter(reader, 0);
        // Dex's invoke-super may name the calling class itself (Pan.init calls `Pan->init` for its super). ART
        // starts that lookup at the superclass; invokespecial on the class's own method calls it again, forever.
        // invoke-direct only reaches constructors and private methods, so other own targets came from invoke-super.
        var inherited = new java.util.HashSet<String>();
        if ((reader.getAccess() & Opcodes.ACC_INTERFACE) == 0 && reader.getSuperName() != null) {
            reader.accept(new ClassVisitor(Opcodes.ASM9) {
                @Override public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                    if ((access & (Opcodes.ACC_PRIVATE | Opcodes.ACC_STATIC)) == 0 && !name.equals("<init>")) inherited.add(name + descriptor);
                    return null;
                }
            }, ClassReader.SKIP_CODE);
        }
        boolean newCz = reader.getClassName().equals("com/github/catvod/spider/NewCz");
        var initialValues = new java.util.ArrayList<InitialValue>();
        boolean[] initializer = { false };
        reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
            // Dex gives any static field an initial value; a class file only primitives, and Strings in String
            // fields. The JVM refuses a class with any other ("Bad string initial value"), so dex2jar's String in
            // an Object field, or class in a Class field, is set first thing in <clinit> instead, as dex does.
            @Override public FieldVisitor visitField(int access, String name, String descriptor, String signature, Object value) {
                if (value != null && (access & Opcodes.ACC_STATIC) != 0 && (descriptor.startsWith("L") || descriptor.startsWith("["))
                        && !(value instanceof String && descriptor.equals("Ljava/lang/String;"))) {
                    if (value instanceof String || value instanceof Type) initialValues.add(new InitialValue(name, descriptor, value));
                    value = null;
                }
                return super.visitField(access, name, descriptor, signature, value);
            }
            @Override public void visitEnd() {
                if (!initialValues.isEmpty() && !initializer[0]) {
                    MethodVisitor method = withInitialValues(super.visitMethod(Opcodes.ACC_STATIC, "<clinit>", "()V", null, null), reader.getClassName(), initialValues);
                    method.visitCode(); method.visitInsn(Opcodes.RETURN); method.visitMaxs(0, 0); method.visitEnd();
                }
                super.visitEnd();
            }
            @Override public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                if ((access & Opcodes.ACC_STATIC) != 0 && ((name.equals("getUrl") && descriptor.equals("()Ljava/lang/String;"))
                        || (name.equals("getOwnProxyUrl") && (descriptor.equals("()Ljava/lang/String;") || descriptor.equals("(Ljava/lang/String;)Ljava/lang/String;"))))
                    && (reader.getClassName().equals("com/github/catvod/spider/ProxyOrigin") || reader.getClassName().equals("com/github/catvod/spider/Proxy"))) {
                    MethodVisitor method = super.visitMethod(access & ~Opcodes.ACC_NATIVE, name, descriptor, signature, exceptions);
                    method.visitCode();
                    if (descriptor.startsWith("(Ljava/lang/String;")) method.visitVarInsn(Opcodes.ALOAD, 0);
                    method.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/CloudDriveBridge", name, descriptor, false);
                    method.visitInsn(Opcodes.ARETURN); method.visitMaxs(1, descriptor.startsWith("(Ljava/lang/String;") ? 1 : 0); method.visitEnd();
                    return null;
                }
                if ((access & Opcodes.ACC_NATIVE) != 0) {
                    MethodVisitor method = super.visitMethod(access & ~Opcodes.ACC_NATIVE, name, descriptor, signature, exceptions);
                    nativeBridge(method, reader.getClassName(), name, descriptor, (access & Opcodes.ACC_STATIC) != 0);
                    return null;
                }
                MethodVisitor target = super.visitMethod(access, name, descriptor, signature, exceptions);
                if (name.equals("<clinit>") && !initialValues.isEmpty()) {
                    initializer[0] = true;
                    target = withInitialValues(target, reader.getClassName(), initialValues);
                }
                return new MethodVisitor(Opcodes.ASM9, target) {
                    @Override public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) {
                        if (opcode == Opcodes.INVOKESPECIAL && owner.equals(reader.getClassName()) && inherited.contains(name + descriptor)) {
                            super.visitMethodInsn(opcode, reader.getSuperName(), name, descriptor, isInterface);
                            return;
                        }
                        if (opcode == Opcodes.INVOKEVIRTUAL && owner.equals("java/lang/Class") && (name.equals("getMethod") || name.equals("getDeclaredMethod")) && descriptor.equals("(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;")) {
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/ReflectionDiagnostics", name, "(Ljava/lang/Class;Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;", false);
                            return;
                        }
                        if (opcode == Opcodes.INVOKEVIRTUAL && owner.equals("java/lang/reflect/Method") && name.equals("invoke") && descriptor.equals("(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;")) {
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/ReflectionDiagnostics", name, "(Ljava/lang/reflect/Method;Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;", false);
                            return;
                        }
                        if (opcode == Opcodes.INVOKESTATIC && name.equals("getProxyUrlDo") && descriptor.equals("(Ljava/lang/String;)Ljava/lang/String;")
                                && (owner.equals("com/github/catvod/spider/Proxy") || owner.equals("com/github/catvod/spider/ProxyOrigin"))) {
                            super.visitMethodInsn(opcode, "tvbox/runtime/CloudDriveBridge", name, descriptor, false);
                            return;
                        }
                        if (opcode == Opcodes.INVOKESTATIC && owner.equals("java/lang/System") && (name.equals("load") || name.equals("loadLibrary")) && descriptor.equals("(Ljava/lang/String;)V")) {
                            super.visitMethodInsn(opcode, "tvbox/runtime/AndroidNativeRuntime", name, descriptor, false);
                            return;
                        }
                        if (owner.equals("okhttp3/Call") && name.equals("execute") && descriptor.equals("()Lokhttp3/Response;")) {
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/HttpDiagnostics", newCz ? "executeNewCz" : "execute", "(Lokhttp3/Call;)Lokhttp3/Response;", false);
                            return;
                        }
                        if (opcode == Opcodes.INVOKEVIRTUAL && connections.contains(owner)
                                && ((name.equals("getResponseCode") && descriptor.equals("()I") && !owner.equals("java/net/URLConnection"))
                                    || (name.equals("getInputStream") && descriptor.equals("()Ljava/io/InputStream;")))) {
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/HttpDiagnostics", name.equals("getResponseCode") ? "responseCode" : "inputStream",
                                "(Ljava/net/URLConnection;)" + descriptor.substring(2), false);
                            return;
                        }
                        if (opcode == Opcodes.INVOKESTATIC && owner.startsWith("java/")) {
                            try {
                                if (Class.forName(owner.replace('/', '.'), false, BytecodeCompatibility.class.getClassLoader()).isInterface()) {
                                    // DEX conversion emits Java 6 classes, which cannot refer to
                                    // static interface methods even with the right constant tag.
                                    var call = new CallSite(owner, name, descriptor);
                                    String bridge = bridges.computeIfAbsent(call, key -> "call" + bridges.size());
                                    super.visitMethodInsn(Opcodes.INVOKESTATIC, bridgeOwner, bridge, descriptor, false);
                                    return;
                                }
                            } catch (ClassNotFoundException ignored) { }
                        }
                        super.visitMethodInsn(opcode, owner, name, descriptor, isInterface);
                    }
                };
            }
        }, 0);
        return writer.toByteArray();
    }

    /** Sets `values` before the rest of <clinit> runs, as dex sets static values before it. */
    private static MethodVisitor withInitialValues(MethodVisitor method, String owner, java.util.List<InitialValue> values) {
        return new MethodVisitor(Opcodes.ASM9, method) {
            @Override public void visitCode() {
                super.visitCode();
                for (InitialValue value : values) {
                    super.visitLdcInsn(value.value());
                    super.visitFieldInsn(Opcodes.PUTSTATIC, owner, value.name(), value.descriptor());
                }
            }
            @Override public void visitMaxs(int maxStack, int maxLocals) { super.visitMaxs(Math.max(maxStack, 1), maxLocals); }
        };
    }

    private static void nativeBridge(MethodVisitor method, String owner, String name, String descriptor, boolean isStatic) {
        method.visitCode();
        if (name.equals("<init>")) {
            method.visitTypeInsn(Opcodes.NEW, "java/lang/UnsupportedOperationException"); method.visitInsn(Opcodes.DUP);
            method.visitLdcInsn("Native Android constructor is not supported: " + owner);
            method.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/UnsupportedOperationException", "<init>", "(Ljava/lang/String;)V", false);
            method.visitInsn(Opcodes.ATHROW);
            method.visitMaxs(3, 1 + java.util.Arrays.stream(Type.getArgumentTypes(descriptor)).mapToInt(Type::getSize).sum()); method.visitEnd(); return;
        }
        method.visitLdcInsn(owner); method.visitLdcInsn(name + descriptor);
        if (isStatic) method.visitInsn(Opcodes.ACONST_NULL); else method.visitVarInsn(Opcodes.ALOAD, 0);
        Type[] arguments = Type.getArgumentTypes(descriptor);
        method.visitLdcInsn(arguments.length); method.visitTypeInsn(Opcodes.ANEWARRAY, "java/lang/Object");
        int local = isStatic ? 0 : 1;
        for (int i = 0; i < arguments.length; i++) {
            Type type = arguments[i];
            method.visitInsn(Opcodes.DUP); method.visitLdcInsn(i); method.visitVarInsn(type.getOpcode(Opcodes.ILOAD), local);
            if (type.getSort() < Type.ARRAY) {
                String wrapper = wrapper(type);
                method.visitMethodInsn(Opcodes.INVOKESTATIC, wrapper, "valueOf", "(" + type.getDescriptor() + ")L" + wrapper + ";", false);
            }
            method.visitInsn(Opcodes.AASTORE); local += type.getSize();
        }
        method.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/AndroidNativeRuntime", "invoke", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;", false);
        Type result = Type.getReturnType(descriptor);
        if (result.getSort() == Type.VOID) { method.visitInsn(Opcodes.POP); method.visitInsn(Opcodes.RETURN); }
        else {
            if (result.getSort() >= Type.ARRAY) method.visitTypeInsn(Opcodes.CHECKCAST, result.getInternalName());
            else {
                String wrapper = wrapper(result);
                method.visitTypeInsn(Opcodes.CHECKCAST, wrapper);
                method.visitMethodInsn(Opcodes.INVOKEVIRTUAL, wrapper, result.getClassName() + "Value", "()" + result.getDescriptor(), false);
            }
            method.visitInsn(result.getOpcode(Opcodes.IRETURN));
        }
        method.visitMaxs(12, local); method.visitEnd();
    }

    private static String wrapper(Type type) {
        return "java/lang/" + switch (type.getSort()) {
            case Type.BOOLEAN -> "Boolean"; case Type.BYTE -> "Byte"; case Type.CHAR -> "Character";
            case Type.SHORT -> "Short"; case Type.INT -> "Integer"; case Type.LONG -> "Long";
            case Type.FLOAT -> "Float"; case Type.DOUBLE -> "Double";
            default -> throw new IllegalArgumentException("Not a primitive type");
        };
    }

    public static void rewrite(Path original, Path destination) throws IOException {
        rewrite(original, destination, BRIDGES);
    }
    public static void rewrite(Path original, Path destination, String bridgeOwner) throws IOException {
        var declared = new java.util.HashMap<String, ConstructorRepair.Declared>();
        try (ZipFile input = new ZipFile(original.toFile())) {
            for (var entries = input.entries(); entries.hasMoreElements();) {
                ZipEntry entry = entries.nextElement();
                if (!entry.getName().endsWith(".class")) continue;
                try (InputStream stream = input.getInputStream(entry)) {
                    ClassReader reader = new ClassReader(stream.readAllBytes());
                    var constructors = new java.util.LinkedHashSet<String>();
                    reader.accept(new ClassVisitor(Opcodes.ASM9) {
                        @Override public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                            if (name.equals("<init>") && (access & Opcodes.ACC_PRIVATE) == 0) constructors.add(descriptor);
                            return null;
                        }
                    }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                    declared.put(reader.getClassName(), new ConstructorRepair.Declared(reader.getSuperName(), constructors));
                }
            }
        }
        try { ConstructorRepair.with(declared::get, () -> { rewriteClasses(original, destination, bridgeOwner); return null; }); }
        catch (IOException | RuntimeException error) { throw error; }
        catch (Exception error) { throw new IOException(error); }
    }
    private static void rewriteClasses(Path original, Path destination, String bridgeOwner) throws IOException {
        Path temporary = Files.createTempFile(destination.getParent(), "compatible-", ".jar");
        try {
            var bridges = new java.util.LinkedHashMap<CallSite, String>();
            try (ZipFile input = new ZipFile(original.toFile()); ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(temporary))) {
                for (var entries = input.entries(); entries.hasMoreElements();) {
                    ZipEntry entry = entries.nextElement();
                    byte[] bytes;
                    try (InputStream stream = input.getInputStream(entry)) { bytes = stream.readAllBytes(); }
                    if (entry.getName().endsWith(".class")) bytes = transform(bytes, bridges, bridgeOwner);
                    output.putNextEntry(new ZipEntry(entry.getName())); output.write(bytes); output.closeEntry();
                }
                if (!bridges.isEmpty()) {
                    ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
                    writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC | Opcodes.ACC_FINAL, bridgeOwner, null, "java/lang/Object", null);
                    for (var entry : bridges.entrySet()) {
                        CallSite call = entry.getKey();
                        MethodVisitor method = writer.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, entry.getValue(), call.descriptor(), null, null);
                        method.visitCode();
                        int local = 0;
                        for (Type argument : Type.getArgumentTypes(call.descriptor())) {
                            method.visitVarInsn(argument.getOpcode(Opcodes.ILOAD), local); local += argument.getSize();
                        }
                        method.visitMethodInsn(Opcodes.INVOKESTATIC, call.owner(), call.name(), call.descriptor(), true);
                        method.visitInsn(Type.getReturnType(call.descriptor()).getOpcode(Opcodes.IRETURN));
                        method.visitMaxs(0, 0); method.visitEnd();
                    }
                    writer.visitEnd();
                    output.putNextEntry(new ZipEntry(bridgeOwner + ".class")); output.write(writer.toByteArray()); output.closeEntry();
                }
            }
            Files.move(temporary, destination, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temporary); }
    }
}
