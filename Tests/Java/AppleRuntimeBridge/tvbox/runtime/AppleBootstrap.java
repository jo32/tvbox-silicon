package tvbox.runtime;

/** Controlled responses for the real JNI bridge, without loading third-party plugins. */
public final class AppleBootstrap {
    public static String request(String input) {
        return switch (input) {
            case "high-surrogate" -> "{\"result\":\"" + (char) 0xd800 + "\"}";
            case "low-surrogate" -> "{\"result\":\"" + (char) 0xdc00 + "\"}";
            // A plugin shortening a title by UTF-16 length, through the middle of the second emoji.
            case "cut-emoji" -> "{\"result\":\"" + "😀😀".substring(0, 3) + "\"}";
            case "reversed-pair" -> "{\"result\":\"" + (char) 0xdc00 + (char) 0xd800 + "\"}";
            case "exception" -> throw new IllegalStateException("Test plugin failure");
            case "out-of-memory" -> throw new OutOfMemoryError("Test plugin allocation failure");
            case "no-response" -> null;
            case "class-space" -> "{\"result\":\"" + java.lang.management.ManagementFactory
                    .getPlatformMXBean(com.sun.management.HotSpotDiagnosticMXBean.class).getVMOption("CompressedClassSpaceSize").getValue() + "\"}";
            default -> input;
        };
    }
}
