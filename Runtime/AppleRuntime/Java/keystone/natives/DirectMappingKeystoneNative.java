package keystone.natives;
import com.sun.jna.*;
import com.sun.jna.ptr.*;
import keystone.*;
/** Apple static linkage: resolve signed assembler symbols from the executable. */
public final class DirectMappingKeystoneNative {
    static {
        var options = new java.util.HashMap<String,Object>();
        options.put(Library.OPTION_TYPE_MAPPER, new keystone.jna.KeystoneTypeMapper());
        Native.register(DirectMappingKeystoneNative.class, NativeLibrary.getProcess(options));
    }
    public static native boolean ks_arch_supported(KeystoneArchitecture arch);
    public static native int ks_asm(Pointer engine, String assembly, long address, PointerByReference output, IntByReference size, IntByReference count);
    public static native KeystoneError ks_close(Pointer engine);
    public static native KeystoneError ks_errno(Pointer engine);
    public static native void ks_free(Pointer pointer);
    public static native KeystoneError ks_open(KeystoneArchitecture arch, KeystoneMode mode, PointerByReference engine);
    public static native KeystoneError ks_option(Pointer engine, KeystoneOptionType type, int value);
    public static native KeystoneError ks_option(Pointer engine, KeystoneOptionType type, SymbolResolverCallback callback);
    public static native String ks_strerror(KeystoneError error);
    public static native int ks_version(IntByReference major, IntByReference minor);
}
