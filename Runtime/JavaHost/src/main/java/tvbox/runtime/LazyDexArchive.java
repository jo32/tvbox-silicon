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
    /**
     * dex2jar's output for each class, before `BytecodeCompatibility.rewrite`. It is keyed by
     * DEX2JAR_VERSION only, so a host update that changes just the rewrite (most of them) re-runs
     * that quick pass on these instead of converting every class from the DEX again.
     */
    private final Path checkpoints;

    public LazyDexArchive(String path, String cache) throws Exception {
        this(path, Path.of(HostEnvironment.converted(Path.of(HostEnvironment.cache(cache),"converted").toString())));
    }

    /** An archive whose converted classes live in `converted` (the folder a runtime's loader would use). */
    public LazyDexArchive(String path, Path converted) throws Exception {
        String hash = sha256(Path.of(path));
        folder = converted.resolve(hash+"."+BytecodeCompatibility.VERSION+"-lazy1");
        checkpoints = converted.resolve(hash+"."+BytecodeCompatibility.DEX2JAR_VERSION);
        Files.createDirectories(folder);
        Files.createDirectories(checkpoints);
        forgetOtherVersions(converted, hash);
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
     * Classes this archive converted under an earlier host version are never read again, and each
     * version left a full copy behind. Remove them once nothing has changed in them for a day (a
     * test build and the release app may take turns on one Mac), off the request's thread.
     */
    private static void forgetOtherVersions(Path converted, String hash) {
        String current = hash + "." + BytecodeCompatibility.VERSION + "-lazy1", checkpoint = hash + "." + BytecodeCompatibility.DEX2JAR_VERSION;
        List<Path> stale = new ArrayList<>();
        try (var entries = Files.newDirectoryStream(converted, hash + ".*")) {
            long cutoff = System.currentTimeMillis() - 24L * 3600 * 1000;
            for (Path entry : entries) {
                String name = entry.getFileName().toString();
                if (name.equals(current) || name.equals(checkpoint) || !Files.isDirectory(entry, LinkOption.NOFOLLOW_LINKS)) continue;
                if (!name.endsWith("-lazy1") && !name.startsWith(hash + ".dex2jar-")) continue;
                if (Files.getLastModifiedTime(entry).toMillis() < cutoff) stale.add(entry);
            }
        } catch (java.io.IOException unreadable) { return; }
        if (stale.isEmpty()) return;
        Thread cleanup = new Thread(() -> {
            for (Path folder : stale) {
                try (var files = Files.walk(folder)) {
                    for (Path file : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(file);
                    System.err.println("DEX_CACHE_REMOVED " + folder.getFileName());
                } catch (java.io.IOException | java.io.UncheckedIOException busy) { }
            }
        }, "converted-cleanup");
        cleanup.setDaemon(true);
        cleanup.setPriority(Thread.MIN_PRIORITY);
        cleanup.start();
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
    public int size() { return indexes.size(); }

    /** Whether a request would load `name` from this archive without converting it. */
    public boolean converted(String name) {
        try { return verified(folder.resolve(classKey(name)+".jar")); }
        catch (Exception unavailable) { return false; }
    }

    /**
     * The archive's other classes that `name` names in its declaration or code (supertypes, and the
     * owners and types its instructions use): what running it is likely to load next. Reads only this
     * class from the DEX and converts nothing.
     */
    public List<String> references(String name) {
        Integer index = indexes.get("L"+name.replace('.','/')+";");
        if (index == null) return List.of();
        Set<String> found = new LinkedHashSet<>();
        java.util.function.Consumer<String> add = type -> {
            if (type == null) return;
            int start = 0;
            while (start < type.length() && type.charAt(start) == '[') start++;
            String element = type.substring(start);
            if (indexes.containsKey(element)) found.add(element.substring(1, element.length() - 1).replace('/', '.'));
        };
        reader.accept(new DexFileVisitor() {
            @Override public DexClassVisitor visit(int access, String className, String parent, String[] interfaces) {
                add.accept(parent);
                if (interfaces != null) for (String type : interfaces) add.accept(type);
                return new DexClassVisitor() {
                    @Override public DexMethodVisitor visitMethod(int accessFlags, com.googlecode.d2j.Method method) {
                        return new DexMethodVisitor() {
                            @Override public DexCodeVisitor visitCode() {
                                return new DexCodeVisitor() {
                                    @Override public void visitMethodStmt(com.googlecode.d2j.reader.Op op, int[] args, com.googlecode.d2j.Method target) { add.accept(target.getOwner()); }
                                    @Override public void visitFieldStmt(com.googlecode.d2j.reader.Op op, int a, int b, com.googlecode.d2j.Field field) { add.accept(field.getOwner()); }
                                    @Override public void visitTypeStmt(com.googlecode.d2j.reader.Op op, int a, int b, String type) { add.accept(type); }
                                    @Override public void visitFilledNewArrayStmt(com.googlecode.d2j.reader.Op op, int[] args, String type) { add.accept(type); }
                                    @Override public void visitConstStmt(com.googlecode.d2j.reader.Op op, int a, Object value) { if (value instanceof com.googlecode.d2j.DexType type) add.accept(type.desc); }
                                    @Override public void visitTryCatch(com.googlecode.d2j.DexLabel start, com.googlecode.d2j.DexLabel end, com.googlecode.d2j.DexLabel[] handlers, String[] types) { if (types != null) for (String type : types) add.accept(type); }
                                };
                            }
                        };
                    }
                };
            }
        }, index, DexFileReader.SKIP_DEBUG | DexFileReader.SKIP_ANNOTATION);
        found.remove(name);
        return new ArrayList<>(found);
    }

    private static String classKey(String name) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(name.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
    }
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
        String key = classKey(name);
        Path result = folder.resolve(key+".jar");
        // Committed artifacts are immutable. Reusing one must not wait behind another
        // class's conversion, which takes seconds per class on the interpreter.
        if(verified(result)) {
            // Staging files of a completed class are leftovers from an interrupted rewrite.
            // (Hosts before DEX2JAR_VERSION kept dex2jar's output here too.)
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
                // dex2jar's output is kept after the rewrite (see `checkpoints`).
                Path raw = checkpoints.resolve(key+".dex.jar");
                Path pending = checkpoints.resolve(key+".dex.tmp");
                Path rewritten = folder.resolve(key+".ready.tmp");
                Files.deleteIfExists(pending);
                Files.deleteIfExists(rewritten);
                Files.deleteIfExists(folder.resolve(key+".dex.jar"));
                if(valid(result,name)) {
                    markVerified(result);
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
                        // An earlier host version (or a run stopped before the rewrite) converted it already.
                        System.err.println("DEX_CLASS_RESUME "+name);
                    }
                    long rewriteStart=System.nanoTime();
                    ConstructorRepair.with(this::declared, () -> { BytecodeCompatibility.rewrite(raw,rewritten,"tvbox/runtime/generated/InterfaceCalls_"+key); return null; });
                    if(!valid(rewritten,name))throw new java.io.IOException("Conversion produced no class: "+name);
                    commit(rewritten,result);
                    markVerified(result);
                    PreparationProgress.converted(1);
                    long end=System.nanoTime();
                    System.err.printf("DEX_CLASS_READY %s %.3fs rewrite=%.3fs%n",name,(end-start)/1e9,(end-rewriteStart)/1e9);
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
