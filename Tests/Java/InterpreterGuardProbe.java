package com.github.unidbg.arm.backend;

import com.github.unidbg.Emulator;
import com.github.unidbg.linux.android.AndroidARM64Emulator;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.AbstractJni;
import com.github.unidbg.debugger.Debugger;
import com.github.unidbg.virtualmodule.android.AndroidModule;
import java.io.File;
import java.nio.file.Files;
import java.util.List;

/** Phase 1 D: uses the TCI JNI library explicitly, with no stock-backend fallback. */
public final class InterpreterGuardProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("Expected TCI JNI library and FishGuard-v8.so paths");
        System.load(new File(args[0]).getAbsolutePath());
        BackendFactory interpreter = new BackendFactory(false) {
            @Override protected Backend newBackendInternal(Emulator<?> emulator, boolean is64Bit) {
                return new Unicorn2Backend(emulator, is64Bit);
            }
        };
        try (var emulator = new AndroidARM64Emulator("com.fongmi.android.tv", Files.createTempDirectory("guard-tci-").toFile(), List.of(interpreter)) {
            @Override protected Debugger createConsoleDebugger() { throw new UnsupportedOperationException("Native guest operation unsupported"); }
        }) {
            emulator.setTimeout(10_000_000L);
            emulator.getMemory().setLibraryResolver(new AndroidResolver(23));
            var vm = emulator.createDalvikVM();
            vm.setVerbose(Boolean.getBoolean("tvbox.traceJNI"));
            vm.setDvmClassFactory(new tvbox.runtime.HierarchyProxyFactory(InterpreterGuardProbe.class.getClassLoader()));
            com.github.catvod.spider.Init.application = new android.app.Application(
                Files.createTempDirectory("guard-profile-").toFile(), InterpreterGuardProbe.class.getClassLoader());
            vm.setJni(new AbstractJni() {});
            new AndroidModule(emulator, vm).register(emulator.getMemory());
            long started = System.nanoTime();
            var module = vm.loadLibrary(new File(args[1]), true);
            module.callJNI_OnLoad(emulator);
            var guard = vm.resolveClass("com/github/catvod/utils/FishNative");
            guard.callStaticJniMethod(emulator, "register()V");
            long ready = System.nanoTime();
            int count = guard.callStaticJniMethodInt(emulator, "svN()I");
            if (count <= 0) throw new IllegalStateException("Guard returned no secure values");
            System.out.printf("TCI guard initialized in %.3f s; guarded svN call in %.3f s; values=%d%n",
                (ready - started) / 1e9, (System.nanoTime() - ready) / 1e9, count);
        }
    }
}
