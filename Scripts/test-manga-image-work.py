#!/usr/bin/env python3
"""Run focused production-code tests without building the app or native media libraries."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="tvcore-focused-") as directory:
    package = Path(directory)
    source = package / "Sources/TVCore"
    tests = package / "Tests/TVCoreTests"
    source.mkdir(parents=True)
    tests.mkdir(parents=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TVCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "TVCore"), .testTarget(name: "TVCoreTests", dependencies: ["TVCore"])
])
''')
    for name in ["MangaImageWork.swift", "MangaLibrary.swift", "MangaNetwork.swift"]:
        shutil.copy2(root / "Sources/TVCore" / name, source)
    shutil.copy2(root / "Tests/Fixtures/MangaImageWork/Stubs.swift", source)
    shutil.copy2(root / "Tests/TVCoreTests/MangaImageWorkTests.swift", tests)
    shutil.copy2(root / "Tests/TVCoreTests/MangaImageTransportTests.swift", tests)
    shutil.copy2(root / "Tests/Fixtures/MangaImageWork/TransformTests.swift", tests)
    raise SystemExit(subprocess.call(["swift", "test", "--package-path", str(package), "-q"]))
