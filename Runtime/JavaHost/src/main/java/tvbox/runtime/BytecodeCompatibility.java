package tvbox.runtime;

import org.objectweb.asm.*;
import java.io.*;
import java.nio.file.*;
import java.util.zip.*;

/** Repairs JVM interface references emitted by the DEX converter and observes plugin HTTP calls. */
public final class BytecodeCompatibility {
    // v11: frames no longer reference the nonexistent java/util/Object; re-convert cached classes.
    public static final String VERSION = "host-v11";

    private static final String BRIDGES = "tvbox/runtime/generated/InterfaceCalls";
    private record CallSite(String owner, String name, String descriptor) { }

    private static byte[] transform(byte[] bytes, java.util.Map<CallSite, String> bridges, String bridgeOwner) {
        ClassReader reader = new ClassReader(bytes);
        ClassWriter writer = new ClassWriter(reader, 0);
        boolean newCz = reader.getClassName().equals("com/github/catvod/spider/NewCz");
        reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
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
                return new MethodVisitor(Opcodes.ASM9, super.visitMethod(access, name, descriptor, signature, exceptions)) {
                    @Override public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) {
                        if (opcode == Opcodes.INVOKEVIRTUAL && owner.equals("java/lang/Class") && (name.equals("getMethod") || name.equals("getDeclaredMethod")) && descriptor.equals("(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;")) {
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/ReflectionDiagnostics", name, "(Ljava/lang/Class;Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;", false);
                            return;
                        }
                        if (opcode == Opcodes.INVOKEVIRTUAL && owner.equals("java/lang/reflect/Method") && name.equals("invoke") && descriptor.equals("(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;")) {
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "tvbox/runtime/ReflectionDiagnostics", name, "(Ljava/lang/reflect/Method;Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;", false);
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
