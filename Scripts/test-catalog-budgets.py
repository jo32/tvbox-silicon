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
    models = (root / "Sources/TVCore/Models.swift").read_text()
    (source / "JSONValue.swift").write_text("import Foundation\n" + models[models.index("public enum JSONValue:"):models.index("public enum WebAddress")])
    catalog = (root / "Sources/TVCore/Catalog.swift").read_text()
    (source / "Catalog.swift").write_text(catalog[:catalog.index("public struct CatalogClient:")])
    discovery = (root / "Sources/TVCore/Discovery.swift").read_text()
    (source / "Results.swift").write_text("import Foundation\n" + discovery[discovery.index("public struct SearchBatch:"):])
    detail = (root / "App/DiscoverDetailView.swift").read_text()
    (source / "DiscoverSources.swift").write_text("import Foundation\nimport Observation\n" +
        detail[detail.index("@MainActor @Observable final class DiscoverSources"):detail.index("private struct DiscoverSourceEpisodes")])
    shutil.copy2(root / "Tests/Fixtures/CatalogBudgets/Stubs.swift", source)
    for name in ["CatalogResponseParser.swift", "SearchPayloadBudget.swift", "SearchModel.swift",
                 "SourceTitleMatch.swift", "TitleMatch.swift", "SeasonTitles.swift"]:
        shutil.copy2(root / "Sources/TVCore" / name, source)
    shutil.copy2(root / "Tests/TVCoreTests/CatalogBudgetTests.swift", tests)
    shutil.copy2(root / "Tests/Fixtures/CatalogBudgets/LifecycleTests.swift", tests)
    raise SystemExit(subprocess.call(["swift", "test", "--package-path", str(package), "-q"]))
