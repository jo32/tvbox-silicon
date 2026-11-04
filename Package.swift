// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TVCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [.library(name: "TVCore", targets: ["TVCore"]), .executable(name: "TVBoxProbe", targets: ["TVBoxProbe"])],
    targets: [.executableTarget(name: "TVBoxProbe", dependencies: ["TVCore"]), .target(name: "TVCore", dependencies: ["DexRuntime", "QuickJS", "TVMedia"], resources: [.process("Resources"), .copy("ScriptAssets"), .copy("WebCast")]),
        .target(name: "DexRuntime", path: "Vendor/DexRuntime", exclude: ["LICENSE", "UPSTREAM.md", "Core/Base/dx_fuzz.c", "Core/DEX/dx_verifier.c"], publicHeadersPath: "include", cSettings: [.define("NDEBUG")], linkerSettings: [.linkedLibrary("z")]), .target(name: "QuickJS", path: "Vendor/QuickJS", exclude: ["LICENSE", "UPSTREAM.md"], sources: ["quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c", "TVScript.c"], publicHeadersPath: "include", cSettings: [.define("_GNU_SOURCE"), .define("QUICKJS_NG_BUILD"), .define("NDEBUG")]),
        // Scripts/build-apple-ffmpeg.sh makes the library Vendor/FFmpeg links to.
        .binaryTarget(name: "FFmpeg", path: "Vendor/FFmpeg/FFmpeg.xcframework"),
        .target(name: "TVMedia", dependencies: ["FFmpeg"], publicHeadersPath: "include", cSettings: [.define("NDEBUG")], linkerSettings: [.linkedLibrary("z"), .linkedFramework("AudioToolbox"), .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"), .linkedFramework("CoreFoundation")]),
        .testTarget(name: "TVCoreTests", dependencies: ["TVCore"], resources: [.copy("Fixtures")])]
)
