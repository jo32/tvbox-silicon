package tvbox.runtime;

import java.io.File;
import java.util.List;
import com.github.unidbg.arm.backend.Unicorn2Factory;
import com.github.unidbg.debugger.Debugger;
import com.github.unidbg.linux.android.AndroidARM64Emulator;

/** The worker's stdin carries requests, never an interactive native debugger. */
public final class HeadlessAndroidEmulator extends AndroidARM64Emulator {
    public HeadlessAndroidEmulator(File root) {
        super("com.fongmi.android.tv", root, List.of(new Unicorn2Factory(true)));
    }
    @Override protected Debugger createConsoleDebugger() {
        throw new UnsupportedOperationException("The plugin requires an Android native operation that this runtime cannot execute.");
    }
}
