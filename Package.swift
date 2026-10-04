// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TVCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [.library(name: "TVCore", targets: ["TVCore"]), .executable(name: "TVBoxProbe", targets: ["TVBoxProbe"])],
    targets: [.executableTarget(name: "TVBoxProbe", dependencies: ["TVCore"]), .target(name: "TVCore", dependencies: ["DexRuntime"], resources: [.process("Resources")]),
        .target(name: "DexRuntime", path: "Vendor/DexRuntime", exclude: ["LICENSE", "UPSTREAM.md", "Core/Base/dx_fuzz.c", "Core/DEX/dx_verifier.c"], publicHeadersPath: "include", cSettings: [.define("NDEBUG")], linkerSettings: [.linkedLibrary("z")]), .testTarget(name: "TVCoreTests", dependencies: ["TVCore"], resources: [.copy("Fixtures")])]
)
