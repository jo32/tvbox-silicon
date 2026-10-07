// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TVCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [.library(name: "TVCore", targets: ["TVCore"]), .executable(name: "TVBoxProbe", targets: ["TVBoxProbe"])],
    targets: [.executableTarget(name: "TVBoxProbe", dependencies: ["TVCore"]), .target(name: "TVCore", dependencies: ["DexRuntime", "QuickJS"], resources: [.process("Resources"), .copy("ScriptAssets")]),
        .target(name: "DexRuntime", path: "Vendor/DexRuntime", exclude: ["LICENSE", "UPSTREAM.md", "Core/Base/dx_fuzz.c", "Core/DEX/dx_verifier.c"], publicHeadersPath: "include", cSettings: [.define("NDEBUG")], linkerSettings: [.linkedLibrary("z")]), .target(name: "QuickJS", path: "Vendor/QuickJS", exclude: ["LICENSE", "UPSTREAM.md"], sources: ["quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c", "TVScript.c"], publicHeadersPath: "include", cSettings: [.define("_GNU_SOURCE"), .define("QUICKJS_NG_BUILD"), .define("NDEBUG")]),
        .testTarget(name: "TVCoreTests", dependencies: ["TVCore"], resources: [.copy("Fixtures")])]
)
