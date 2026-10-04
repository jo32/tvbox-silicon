package tvbox.runtime;

import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.*;
import com.github.unidbg.virtualmodule.android.AndroidModule;
import java.io.File;

/** Runs the actual Android ELF library in an emulated guest CPU, never Darwin dlopen. */
public class NativeProbe extends AbstractJni {
    public static void main(String[] args) throws Exception {
        java.security.Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider());
        var output = System.out;
        System.setOut(System.err);
        boolean serving = args.length == 2 && args[0].equals("--serve");
        var input = new org.json.JSONObject(java.nio.file.Files.readString(new File(args[serving ? 1 : 0]).toPath()));
        try {
            PluginSession session = initialize(input);
            if (serving) serve(session, input);
            else { output.println(new org.json.JSONObject().put("result", session.request(input.getJSONObject("params")))); output.flush(); }
            Runtime.getRuntime().halt(0);
        } catch (Throwable error) {
            var failure = failure(error);
            if (serving) writeResponse(new File(input.getString("cache"), "ready.json"), failure);
            else { output.println(failure); output.flush(); }
            Runtime.getRuntime().halt(1);
        }
    }

    private static org.json.JSONObject failure(Throwable error) throws Exception {
        error.printStackTrace(System.err);
        var result = new org.json.JSONObject().put("error", error.toString());
        Throwable cause = error;
        var visited = java.util.Collections.newSetFromMap(new java.util.IdentityHashMap<Throwable, Boolean>());
        while (cause.getCause() != null && visited.add(cause)) cause = cause.getCause();
        if (cause != error) result.put("error", error + ": " + cause);
        if (error instanceof HttpDiagnostics.SourceHTTPException remote) {
            result.put("errorCode", "source_http").put("host", remote.host).put("status", remote.status);
        } else if (error instanceof PluginSession.EmptyContentException) {
            result.put("errorCode", "source_empty");
        } else if (error instanceof java.io.IOException && HttpDiagnostics.host != null) {
            result.put("errorCode", "source_network").put("host", HttpDiagnostics.host);
        } else if (error instanceof UnsupportedOperationException && "Missing ftyguard_v8.so".equals(error.getMessage())) {
            result.put("errorCode", "unsupported_native_library");
        } else if (cause instanceof LinkageError || cause instanceof UnsupportedOperationException
            || (cause instanceof RuntimeException && "Stub!".equals(cause.getMessage()))) {
            result.put("errorCode", "unsupported_android");
        }
        return result;
    }

    private static void serve(PluginSession session, org.json.JSONObject input) throws Exception {
        File cache = new File(input.getString("cache"));
        File responses = new File(cache, "responses"); responses.mkdirs();
        writeResponse(new File(cache, "ready.json"), new org.json.JSONObject().put("ready", true));
        var reader = new java.io.BufferedReader(new java.io.InputStreamReader(System.in, java.nio.charset.StandardCharsets.UTF_8));
        String line;
        while ((line = reader.readLine()) != null) {
            var command = new org.json.JSONObject(line);
            String id = command.getString("id");
            if (!id.matches("[A-Za-z0-9-]{1,80}")) throw new IllegalArgumentException("Invalid request identifier");
            org.json.JSONObject response;
            try { response = new org.json.JSONObject().put("result", session.request(command.getJSONObject("params"))); }
            catch (Throwable error) { response = failure(error); }
            writeResponse(new File(responses, id + ".json"), response);
        }
    }

    private static void writeResponse(File file, org.json.JSONObject response) throws Exception {
        var temporary = new File(file.getPath() + ".tmp").toPath();
        java.nio.file.Files.writeString(temporary, response.toString(), java.nio.charset.StandardCharsets.UTF_8);
        java.nio.file.Files.move(temporary, file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
    }

    private static PluginSession initialize(org.json.JSONObject input) throws Exception {
        File cache = new File(input.getString("cache")); cache.mkdirs();
        File session = java.nio.file.Files.createTempDirectory(cache.toPath(), "session-").toFile();
        System.setProperty("tvbox.cache", cache.getAbsolutePath());
        if (input.has("conversionCache")) System.setProperty("tvbox.converted", input.getString("conversionCache"));
        var bridge = new CloudDriveBridge(cache.toPath());
        org.json.JSONObject accounts = null;
        if (input.has("cloudAccounts")) {
            var accountPath = java.nio.file.Path.of(input.getString("cloudAccounts"));
            if (java.nio.file.Files.isRegularFile(accountPath)) accounts = new org.json.JSONObject(java.nio.file.Files.readString(accountPath));
        }
        input.put("ext", bridge.extension(input.optString("ext"), accounts));
        File jar = new File(input.getString("jar"));
        System.setProperty("tvbox.plugin", jar.getAbsolutePath());
        File library = new File(session, "ftyguard_v8.so");
        try(var zip = new java.util.zip.ZipFile(jar)) {
            var entry = zip.getEntry("assets/ftyguard_v8.so");
            if (entry == null) return initializeStandard(input, jar, cache, bridge, accounts);
            try(var stream=zip.getInputStream(entry)) { java.nio.file.Files.copy(stream, library.toPath()); }
        }
        File root = new File(session, "guest"); root.mkdirs();
        AndroidEmulator emulator = new HeadlessAndroidEmulator(root);
        {
            emulator.setTimeout(10_000_000L);
            emulator.getMemory().setLibraryResolver(new AndroidResolver(23));
            VM vm = emulator.createDalvikVM();
            vm.setDvmClassFactory(new HierarchyProxyFactory(NativeProbe.class.getClassLoader()).configClassNameMapper(name -> {
                try { return Class.forName(name, false, NativeProbe.class.getClassLoader()); }
                catch (ClassNotFoundException missing) {
                    try { return dalvik.system.DexClassLoader.current == null ? null : dalvik.system.DexClassLoader.current.loadClass(name); }
                    catch (ClassNotFoundException ignored) { return null; }
                }
            }));
            vm.setJni(new NativeProbe());
            var jarLoader = new java.net.URLClassLoader(new java.net.URL[]{ jar.toURI().toURL() }, NativeProbe.class.getClassLoader());
            var context = new android.app.Application(new File(input.optString("profile", new File(cache, "profile").getPath())), jarLoader);
            com.github.catvod.spider.Init.application = context;
            vm.setVerbose(Boolean.getBoolean("tvbox.traceJNI"));
            new AndroidModule(emulator, vm).register(emulator.getMemory());
            DalvikModule module = vm.loadLibrary(library, true);
            module.callJNI_OnLoad(emulator);
            System.out.println("JNI_ONLOAD_OK");
            DvmClass nativeClass = vm.resolveClass("com/github/catvod/spider/DexNative");
            NativeCalls.emulator = emulator; NativeCalls.vm = vm; NativeCalls.nativeClass = nativeClass;
            DvmObject<?> value = nativeClass.callStaticJniMethodObject(emulator,
                "native_ting_md5(Ljava/lang/String;)Ljava/lang/String;", new StringObject(vm, "tvbox-runtime-probe"));
            System.out.println("NATIVE_RESULT=" + (value == null ? "null" : value.getValue()));
            var loader = nativeClass.callStaticJniMethodObject(emulator, "getLoader(Ljava/lang/Object;)Ljava/lang/Object;",
                com.github.unidbg.linux.android.dvm.jni.ProxyDvmObject.createObject(vm, context));
            System.out.println("LOADER_RESULT=" + (loader == null ? "null" : loader.getValue()));
            if(loader == null) throw new IllegalStateException("Plugin loader failed");
            Object spider = com.github.catvod.spider.DexNative.getSpider(loader.getValue(), "com.github.catvod.spider." + input.getString("api").replace("csp_", ""));
            if(spider == null) throw new IllegalStateException("Spider creation failed");
            System.out.println("SPIDER=" + spider.getClass().getName());
            com.github.catvod.crawler.Spider actual = (com.github.catvod.crawler.Spider)spider;
            actual.siteKey = input.optString("key");
            actual.init(context, input.optString("ext"));
            bridge.setDriveProxy(dalvik.system.DexClassLoader.current);
            bridge.setProxy(params -> com.github.catvod.spider.DexNative.proxyInvoke(loader.getValue(), params));
            return new PluginSession(actual, null, bridge);
        }
    }

    /** Ordinary CatVod archives do not require the FTY-specific native loader. */
    private static PluginSession initializeStandard(org.json.JSONObject input, File jar, File cache, CloudDriveBridge bridge, org.json.JSONObject accounts) throws Exception {
        var loader = new PluginClassLoader(jar.getAbsolutePath(), cache.getAbsolutePath(), NativeProbe.class.getClassLoader());
        AndroidNativeRuntime.configure(loader, jar, cache);
        var context = new android.app.Application(new File(input.optString("profile", new File(cache, "profile").getPath())), loader);
        com.github.catvod.spider.Init.application = context;
        Throwable initializationWarning = null;
        try {
            Class<?> init = loader.loadClass("com.github.catvod.spider.Init");
            init.getMethod("init", android.content.Context.class).invoke(null, context);
        } catch (ClassNotFoundException | NoSuchMethodException absent) {
            // Init is an optional CatVod hook, not a requirement for every plugin.
        } catch (java.lang.reflect.InvocationTargetException failure) {
            // Some plugins start optional Android UI/proxy services here. A source
            // that can return content independently should still be callable.
            initializationWarning = failure.getCause();
            initializationWarning.printStackTrace(System.err);
        }
        String api = input.getString("api");
        if (!api.startsWith("csp_")) throw new IllegalArgumentException("Expected a csp_ plugin class");
        var spider = (com.github.catvod.crawler.Spider)loader.loadClass("com.github.catvod.spider." + api.substring(4)).getDeclaredConstructor().newInstance();
        spider.siteKey = input.optString("key");
        spider.init(context, bridge.cloudExtension(input.optString("ext"), accounts, spider.getClass()));
        bridge.setDriveProxy(loader);
        bridge.setProxy(params -> {
            try { return (Object[])loader.loadClass("com.github.catvod.spider.Proxy").getMethod("proxy", java.util.Map.class).invoke(null, params); }
            catch (ClassNotFoundException | NoSuchMethodException absent) { return spider.proxy(params); }
        });
        return new PluginSession(spider, initializationWarning, bridge);
    }
}
