package tvbox.runtime;

import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.reader.*;
import com.googlecode.d2j.visitors.*;
import java.nio.file.*;
import java.nio.channels.FileChannel;
import java.security.MessageDigest;
import java.util.*;
import java.util.jar.JarFile;

/** Converts only classes actually requested, preserving the full type hierarchy. */
public final class LazyDexArchive {
    private record Header(int access, String name, String parent, String[] interfaces) {}
    private final BaseDexFileReader reader;
    private final List<Header> headers = new ArrayList<>();
    private final Map<String,Integer> indexes = new HashMap<>();
    private final Path folder;

    public LazyDexArchive(String path, String cache) throws Exception {
        String hash = sha256(Path.of(path));
        String fallback = Path.of(HostEnvironment.cache(cache),"converted").toString();
        folder = Path.of(HostEnvironment.converted(fallback),hash+"."+BytecodeCompatibility.VERSION+"-lazy1");
        Files.createDirectories(folder);
        reader = mapped(Path.of(path), folder);
        List<String> names = reader.getClassNames();
        for (int i=0;i<names.size();i++) indexes.put(names.get(i),i);
        reader.accept(new DexFileVisitor() {
            @Override public DexClassVisitor visit(int access, String name, String parent, String[] interfaces) {
                headers.add(new Header(access,name,parent,interfaces));
                return null; // Index only; skip every method body.
            }
        }, DexFileReader.SKIP_CODE | DexFileReader.SKIP_DEBUG | DexFileReader.SKIP_ANNOTATION);
        System.err.println("DEX_INDEX_READY classes="+indexes.size()+" "+HeapBudget.describe());
    }

    private static String sha256(Path path) throws Exception {
        var digest = MessageDigest.getInstance("SHA-256");
        try (var input = Files.newInputStream(path)) {
            byte[] buffer = new byte[64 * 1024];
            for (int count; (count = input.read(buffer)) > 0; ) digest.update(buffer, 0, count);
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    /**
     * The reader stays alive for the runtime's lifetime (classes convert on demand). Reading the
     * archive into the heap kept a whole copy of every DEX there, and growing that copy briefly
     * needed about three times its size. Extract each DEX once next to the converted classes and
     * map it instead: the pages live outside the Java heap, and the OS can drop and reload them.
     */
    private static BaseDexFileReader mapped(Path archive, Path folder) throws Exception {
        byte[] magic = new byte[4];
        try (var input = Files.newInputStream(archive)) { input.readNBytes(magic, 0, 4); }
        if (magic[0] == 'd' && magic[1] == 'e' && magic[2] == 'x') return new DexFileReader(map(archive));
        // Same entries and order as MultiDexFileReader.open: classes*.dex, sorted by name.
        var dexes = new TreeMap<String, DexFileReader>();
        try (var zip = new java.util.zip.ZipFile(archive.toFile())) {
            var entries = zip.entries();
            while (entries.hasMoreElements()) {
                var entry = entries.nextElement();
                String name = entry.getName();
                if (entry.isDirectory() || !name.startsWith("classes") || !name.endsWith(".dex") || name.contains("/")) continue;
                Path extracted = folder.resolve(name);
                if (!Files.isRegularFile(extracted) || Files.size(extracted) != entry.getSize()) extract(zip, entry, extracted);
                DexFileReader dex;
                try { dex = new DexFileReader(map(extracted)); }
                catch (RuntimeException damaged) {
                    // A damaged copy with the right size: replace it from the archive once.
                    extract(zip, entry, extracted);
                    dex = new DexFileReader(map(extracted));
                }
                dexes.put(name, dex);
            }
        }
        if (dexes.isEmpty()) throw new java.io.IOException("Can not find classes.dex in " + archive);
        return dexes.size() == 1 ? dexes.firstEntry().getValue() : new MultiDexFileReader(dexes.values());
    }

    /** Readers of an earlier copy keep their mapping; the replacement is moved in atomically. */
    private static void extract(java.util.zip.ZipFile zip, java.util.zip.ZipEntry entry, Path extracted) throws java.io.IOException {
        Path pending = Files.createTempFile(extracted.getParent(), entry.getName(), ".tmp");
        try {
            try (var input = zip.getInputStream(entry)) { Files.copy(input, pending, StandardCopyOption.REPLACE_EXISTING); }
            if (Files.size(pending) != entry.getSize()) throw new java.io.IOException("Truncated " + entry.getName());
            try (var channel = FileChannel.open(pending, StandardOpenOption.WRITE)) { channel.force(true); }
            Files.move(pending, extracted, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(pending); }
    }

    private static java.nio.ByteBuffer map(Path file) throws java.io.IOException {
        // The mapping outlives the channel.
        try (var channel = FileChannel.open(file, StandardOpenOption.READ)) {
            return channel.map(FileChannel.MapMode.READ_ONLY, 0, channel.size());
        }
    }
    private final Map<String, ConstructorRepair.Declared> declared = new java.util.concurrent.ConcurrentHashMap<>();
    /** Superclass and constructors of a plugin class, read from the DEX without converting it. */
    private ConstructorRepair.Declared declared(String name) {
        Integer index = indexes.get("L" + name + ";");
        if (index == null) return null;
        return declared.computeIfAbsent(name, key -> {
            String[] parent = { null };
            Set<String> constructors = new LinkedHashSet<>();
            reader.accept(new DexFileVisitor() {
                @Override public DexClassVisitor visit(int access, String className, String superName, String[] interfaces) {
                    if (!className.equals("L" + key + ";")) return null;
                    if (superName != null) parent[0] = superName.substring(1, superName.length() - 1);
                    return new DexClassVisitor() {
                        @Override public DexMethodVisitor visitMethod(int accessFlags, com.googlecode.d2j.Method method) {
                            if (method.getName().equals("<init>") && (accessFlags & 0x2) == 0) constructors.add(method.getDesc());
                            return null;
                        }
                    };
                }
            }, index, DexFileReader.SKIP_CODE | DexFileReader.SKIP_DEBUG | DexFileReader.SKIP_ANNOTATION);
            return new ConstructorRepair.Declared(parent[0], constructors);
        });
    }
    public boolean contains(String name) { return indexes.containsKey("L"+name.replace('.','/')+";"); }
    /**
     * FileChannel and NIO writes are interruptible. Plugins interrupt their own worker threads
     * (timeouts, cancelled futures); a conversion that fails that way is cached by the JVM as a
     * NoClassDefFoundError until restart. Convert with the flag cleared and restore it afterwards.
     */
    public Path prepare(String name) throws Exception {
        boolean interrupted = Thread.interrupted();
        try {
            for (int attempt = 1; ; attempt++) {
                try { return prepareOnce(name); }
                catch (java.nio.channels.ClosedByInterruptException | java.nio.channels.FileLockInterruptionException again) {
                    interrupted = true;
                    Thread.interrupted();
                    if (attempt == 3) throw again;
                }
            }
        } finally { if (interrupted) Thread.currentThread().interrupt(); }
    }

    private Path prepareOnce(String name) throws Exception {
        String descriptor = "L"+name.replace('.','/')+";";
        Integer index = indexes.get(descriptor);
        if(index==null) throw new ClassNotFoundException(name);
        String key = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(name.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        Path result = folder.resolve(key+".jar");
        // Committed artifacts are immutable. Reusing one must not wait behind another
        // class's conversion, which takes seconds per class on the interpreter.
        if(verified(result)) {
            // Staging files of a completed class are leftovers from an interrupted rewrite.
            for(String suffix:new String[]{".dex.tmp",".ready.tmp",".dex.jar"}) Files.deleteIfExists(folder.resolve(key+suffix));
            PreparationProgress.reused(1); return result;
        }
        Path lockFile = folder.resolve(key+".lock");
        // Each plugin runtime has its own Dex2jar class, and FileChannel.lock throws (rather than
        // waits) when another thread of this JVM holds the file. The interned path is JVM-wide.
        synchronized(Dex2jar.class) { synchronized(lockFile.toString().intern()) {
            try(var channel=FileChannel.open(lockFile,StandardOpenOption.CREATE,StandardOpenOption.WRITE);var lock=channel.lock()) {
                // All staging paths belong to this class and are protected by its lock.
                // A killed process cannot leave a partial file that looks committed.
                Path raw = folder.resolve(key+".dex.jar");
                Path pending = folder.resolve(key+".dex.tmp");
                Path rewritten = folder.resolve(key+".ready.tmp");
                Files.deleteIfExists(pending);
                Files.deleteIfExists(rewritten);
                if(valid(result,name)) {
                    markVerified(result);
                    Files.deleteIfExists(raw);
                    PreparationProgress.reused(1); return result;
                }
                PreparationProgress.converting();
                long start=System.nanoTime();
                System.err.println("DEX_CLASS_BEGIN "+name);
                BaseDexFileReader selected = new BaseDexFileReader() {
                    public int getDexVersion() { return reader.getDexVersion(); }
                    public List<String> getClassNames() { return List.of(descriptor); }
                    public void accept(DexFileVisitor visitor) { accept(visitor,0); }
                    public void accept(DexFileVisitor visitor,int config) {
                        visitor.visitDexFileVersion(getDexVersion());
                        for(Header header:headers) {
                            if(header.name().equals(descriptor)) continue;
                            var c=visitor.visit(header.access(),header.name(),header.parent(),header.interfaces());
                            if(c!=null)c.visitEnd();
                        }
                        reader.accept(visitor,index,config);
                    }
                    public void accept(DexFileVisitor visitor,int classIndex,int config) { accept(visitor,config); }
                };
                try {
                    if (!valid(raw,name)) {
                        Files.deleteIfExists(raw);
                        Dex2jar.from(selected).onlyClass(name.replace('.','/')).skipDebug(true).computeFrames(true).to(pending);
                        if(!valid(pending,name))throw new java.io.IOException("Conversion produced no class: "+name);
                        commit(pending,raw);
                    } else {
                        System.err.println("DEX_CLASS_RESUME "+name);
                    }
                    ConstructorRepair.with(this::declared, () -> { BytecodeCompatibility.rewrite(raw,rewritten,"tvbox/runtime/generated/InterfaceCalls_"+key); return null; });
                    if(!valid(rewritten,name))throw new java.io.IOException("Conversion produced no class: "+name);
                    commit(rewritten,result);
                    markVerified(result);
                    Files.deleteIfExists(raw);
                    PreparationProgress.converted(1);
                    System.err.printf("DEX_CLASS_READY %s %.3fs%n",name,(System.nanoTime()-start)/1e9);
                } finally { Files.deleteIfExists(pending);Files.deleteIfExists(rewritten); }
                return result;
            }
        } }
    }
    private static void commit(Path source,Path target) throws java.io.IOException {
        try(var channel=FileChannel.open(source,StandardOpenOption.WRITE)) { channel.force(true); }
        Files.move(source,target,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
    }
    /** A fully validated artifact gets a size/time stamp, so later launches skip re-reading every entry. */
    private static boolean verified(Path result) {
        try {
            Path stamp = result.resolveSibling(result.getFileName()+".ok");
            return Files.isRegularFile(result) && Files.isRegularFile(stamp) && Files.readString(stamp).equals(stamp(result));
        } catch(java.io.IOException unreadable) { return false; }
    }
    private static void markVerified(Path result) {
        Path stamp = result.resolveSibling(result.getFileName()+".ok");
        Path pending = result.resolveSibling(result.getFileName()+".ok.tmp");
        try {
            Files.writeString(pending, stamp(result));
            Files.move(pending, stamp, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch(java.io.IOException ignored) {
            // Without a stamp the next launch validates the artifact again.
            try { Files.deleteIfExists(pending); } catch(java.io.IOException cleanupIgnored) { }
        }
    }
    private static String stamp(Path path) throws java.io.IOException {
        return Files.size(path)+":"+Files.getLastModifiedTime(path).toMillis();
    }
    private static boolean valid(Path path,String name) {
        if(!Files.isRegularFile(path))return false;
        try(var jar=new JarFile(path.toFile())) {
            String expected=name.replace('.','/');
            if(jar.getJarEntry(expected+".class")==null)return false;
            var entries=jar.entries();
            while(entries.hasMoreElements()) {
                var entry=entries.nextElement();
                if(entry.isDirectory())continue;
                byte[] bytes;
                try(var input=jar.getInputStream(entry)) { bytes=input.readAllBytes(); }
                var crc=new java.util.zip.CRC32(); crc.update(bytes);
                if(entry.getSize()!=bytes.length || entry.getCrc()!=crc.getValue())return false;
                if(entry.getName().endsWith(".class")) {
                    var reader=new org.objectweb.asm.ClassReader(bytes);
                    if(!entry.getName().equals(reader.getClassName()+".class"))return false;
                }
            }
            return true;
        } catch(java.io.IOException | RuntimeException error) { return false; }
    }
}
