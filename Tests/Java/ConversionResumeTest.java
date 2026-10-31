import tvbox.runtime.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** A separate JVM is killed, so no in-memory loader state can satisfy reuse. */
public final class ConversionResumeTest {
    static final String FIXTURE="Tests/TVCoreTests/Fixtures/runtime-probe.jar";
    static final String CLASS="tvbox.RuntimeProbe";
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    static Path prepare(Path root)throws Exception {
        PreparationProgress.begin(root);
        Path result=new LazyDexArchive(FIXTURE,root.toString()).prepare(CLASS);
        PreparationProgress.loading();
        return result;
    }
    public static void main(String[] args)throws Exception {
        if(args.length>0) {
            Path root=Path.of(args[0]); Path result=prepare(root);
            // Mimic a crash while the next class is being written. These staging
            // files must not invalidate the already committed class.
            String key=result.getFileName().toString().replace(".jar","");
            Files.writeString(result.resolveSibling(key+".dex.tmp"),"partial");
            Files.writeString(result.resolveSibling(key+".ready.tmp"),"partial");
            System.out.println(result);System.out.flush();
            Thread.sleep(60_000);return;
        }
        Path root=Files.createTempDirectory("conversion-resume-test");
        Process child=null;
        try {
            child=new ProcessBuilder(Path.of(System.getProperty("java.home"),"bin/java").toString(),
                "-cp",System.getProperty("java.class.path"),ConversionResumeTest.class.getName(),root.toString())
                .redirectError(root.resolve("child.log").toFile()).start();
            final Process running=child;
            var line=java.util.concurrent.CompletableFuture.supplyAsync(()->{
                try{return running.inputReader().readLine();}catch(Exception e){throw new RuntimeException(e);}
            }).get(20,TimeUnit.SECONDS);
            check(line!=null,"Child failed before checkpoint");
            Path completed=Path.of(line);var timestamp=Files.getLastModifiedTime(completed);
            byte[] original=Files.readAllBytes(completed);
            child.destroyForcibly();check(child.waitFor(10,TimeUnit.SECONDS),"Child did not stop");
            check(prepare(root).equals(completed),"Resume selected a different cache");
            check(Files.getLastModifiedTime(completed).equals(timestamp),"Completed conversion was repeated");
            check(Files.readString(root.resolve("preparation-progress.json")).contains("\"reused\":1"),"Resume not reported as reuse");
            try(var paths=Files.walk(root)){check(paths.noneMatch(p->p.toString().endsWith(".tmp")),"Stale partial writes survived");}

            // dex2jar's output stays next to the converted classes, keyed by DEX2JAR_VERSION only, so a host
            // version that changes only the rewrite reuses it.
            String key=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(CLASS.getBytes(StandardCharsets.UTF_8)));
            String hash=completed.getParent().getFileName().toString().split("\\.")[0];
            Path raw=completed.getParent().resolveSibling(hash+"."+BytecodeCompatibility.DEX2JAR_VERSION).resolve(key+".dex.jar");
            check(Files.isRegularFile(raw),"dex2jar's output was not kept");
            check(!Files.exists(completed.resolveSibling(key+".dex.jar")),"dex2jar's output was kept with the rewritten classes");
            // Persist actual dex2jar output, representing a stop before rewrite or a new host version.
            com.googlecode.d2j.dex.Dex2jar.from(Path.of(FIXTURE).toFile()).onlyClass(CLASS.replace('.','/')).skipDebug(true).computeFrames(true).to(raw);
            Files.delete(completed);
            var captured=new java.io.ByteArrayOutputStream();var previous=System.err;
            try {System.setErr(new java.io.PrintStream(captured));prepare(root);}finally{System.setErr(previous);}
            check(captured.toString().contains("DEX_CLASS_RESUME "+CLASS),"Raw checkpoint was not resumed");
            check(Files.isRegularFile(raw),"dex2jar's output was not kept for the next host version");
            // dex2jar numbers locals in identity-hash order, so separate JVMs can emit equivalent
            // classes with swapped slots. Require the same size and behavior, not identical bytes.
            check(original.length==Files.readAllBytes(completed).length,"Resumed bytecode differs");
            try(var loader=new java.net.URLClassLoader(new java.net.URL[]{completed.toUri().toURL()},ConversionResumeTest.class.getClassLoader())){
                check((int)loader.loadClass(CLASS).getMethod("run").invoke(null)==42,"Resumed conversion does not execute");
            }

            Files.delete(completed);Files.writeString(raw,"truncated checkpoint");
            prepare(root);
            try(var loader=new java.net.URLClassLoader(new java.net.URL[]{completed.toUri().toURL()},ConversionResumeTest.class.getClassLoader())){
                check((int)loader.loadClass(CLASS).getMethod("run").invoke(null)==42,"Repaired conversion does not execute");
            }

            // Folders of earlier host versions go once nothing has changed in them for a day.
            Path converted=completed.getParent().getParent();
            long old=System.currentTimeMillis()-2L*24*3600*1000;
            Path[] stale={converted.resolve(hash+".host-v0-lazy1"),converted.resolve(hash+".dex2jar-v0")};
            Path recent=converted.resolve(hash+".host-v1-lazy1"), other=converted.resolve("0".repeat(64)+".host-v0-lazy1");
            for(Path folder:new Path[]{stale[0],stale[1],recent,other}) {
                Files.createDirectories(folder);Files.writeString(folder.resolve("x.jar"),"x");
                if(folder!=recent)Files.setLastModifiedTime(folder,java.nio.file.attribute.FileTime.fromMillis(old));
            }
            prepare(root);
            for(int i=0;i<100 && (Files.exists(stale[0])||Files.exists(stale[1]));i++)Thread.sleep(50);
            check(!Files.exists(stale[0])&&!Files.exists(stale[1]),"Earlier host versions were kept");
            check(Files.exists(recent),"A host version used today was removed");
            check(Files.exists(other),"Another archive's classes were removed");
            check(Files.exists(completed)&&Files.exists(raw),"The current classes were removed");
            System.out.println("ConversionResumeTest passed: forced process death, completed reuse, staging cleanup, raw-stage resume, kept dex2jar output, corrupt checkpoint recovery, old version cleanup");
        } finally {
            if(child!=null && child.isAlive()){child.destroyForcibly();child.waitFor();}
            try(var files=Files.walk(root)){for(Path p:files.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(p);}
        }
    }
}
