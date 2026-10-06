import dalvik.system.DexClassLoader;
import java.nio.file.*;
import java.util.*;

public final class LazyDexTest {
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception{
        Path root=Files.createTempDirectory("lazy-dex-test");
        String previous=System.getProperty("tvbox.lazyDex");
        System.setProperty("tvbox.lazyDex","true");
        try{
            Path cached;
            try(var loader=new DexClassLoader("Tests/TVCoreTests/Fixtures/runtime-probe.jar",root.toString(),"",LazyDexTest.class.getClassLoader())){
                try(var files=Files.walk(root)){check(files.noneMatch(p->p.toString().endsWith(".jar")),"Indexing eagerly converted classes");}
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null)==42,"On-demand conversion did not execute");
                try(var files=Files.walk(root)){cached=files.filter(p->p.toString().endsWith(".jar")).findFirst().orElseThrow();}
            }
            var timestamp=Files.getLastModifiedTime(cached);
            try(var loader=new DexClassLoader("Tests/TVCoreTests/Fixtures/runtime-probe.jar",root.toString(),"",LazyDexTest.class.getClassLoader())){
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null)==42,"Cached class failed");
                check(Files.getLastModifiedTime(cached).equals(timestamp),"Warm load repeated conversion");
            }
            Files.writeString(cached,"truncated cache");
            try(var loader=new DexClassLoader("Tests/TVCoreTests/Fixtures/runtime-probe.jar",root.toString(),"",LazyDexTest.class.getClassLoader())){
                check((int)loader.loadClass("tvbox.RuntimeProbe").getMethod("run").invoke(null)==42,"Corrupt cache not repaired");
                check(loader.getResource("classes.dex")!=null,"Original DEX resource lost");
            }
            System.out.println("LazyDexTest passed: deferred conversion, execution, cache reuse, corruption recovery, assets");
        }finally{
            if(previous==null)System.clearProperty("tvbox.lazyDex");else System.setProperty("tvbox.lazyDex",previous);
            try(var files=Files.walk(root)){for(Path p:files.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(p);}
        }
    }
}
