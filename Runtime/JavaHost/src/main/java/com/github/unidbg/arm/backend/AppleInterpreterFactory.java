package com.github.unidbg.arm.backend;
import com.github.unidbg.Emulator;
/** Explicit TCI-only selection; never falls back to executable-memory backends. */
public final class AppleInterpreterFactory extends BackendFactory {
    public AppleInterpreterFactory() { super(false); }
    @Override protected Backend newBackendInternal(Emulator<?> emulator, boolean is64Bit) {
        if (!is64Bit) throw new UnsupportedOperationException("Only ARM64 guards are supported");
        return new Unicorn2Backend(emulator, true);
    }
}
