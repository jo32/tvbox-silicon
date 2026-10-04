package dalvik.system;

/** Runtime introspection for plugins choosing their Android ARM64 assets. */
public final class VMRuntime {
    private static final VMRuntime INSTANCE = new VMRuntime();
    public static VMRuntime getRuntime() { return INSTANCE; }
    public boolean is64Bit() { return true; }
    public String vmInstructionSet() { return "arm64"; }
}
