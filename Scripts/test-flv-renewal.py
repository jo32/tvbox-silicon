#!/usr/bin/env python3
"""Production FLV session over controlled URLProtocol HTTP; no application/native media build."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='flv-renewal-') as temp:
    folder = Path(temp)
    source = (root / 'Sources/TVCore/FLVLive.swift').read_text()
    source = source.replace('configuration.urlCache = nil', 'configuration.urlCache = nil\n        configuration.protocolClasses = [FixtureProtocol.self]')
    main = (root / 'Tests/Standalone/FLVRenewal/Main.swift').read_text()
    (folder / 'FLVLive.swift').write_text(source)
    (folder / 'Main.swift').write_text(main)
    catalog = (root / 'Sources/TVCore/Catalog.swift').read_text()
    def method(marker):
        start = catalog.index(marker)
        opening = catalog.index('{', start)
        depth, end = 1, opening + 1
        while depth:
            depth += (catalog[end] == '{') - (catalog[end] == '}')
            end += 1
        return catalog[start:end].replace('public func', 'func')
    wrappers = '\n'.join(method(marker) for marker in ['    public func preparePlayback(', '    public func resolvePlayback('])
    (folder / 'Catalog.swift').write_text('import Foundation\nstruct CatalogClient: Sendable {\n let backend: CatalogFixture\n var site = CatalogSite()\n' + wrappers + '''
    private func preparePlaybackPlan(_ episode: Episode, forDownload: Bool, fresh: Bool = false) async throws -> PlaybackPlan { await backend.prepare(episode, fresh: fresh) }
    private func resolvePlaybackChannel(_ plan: PlaybackPlan, choice: PlaybackChoice) async throws -> Channel { Channel(url: URL(string: choice.address)!, headers: plan.headers) }
}
''')
    binary = folder / 'check'
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(folder/'FLVLive.swift'),str(root/'Tests/Standalone/FLVRenewal/Support.swift'),str(folder/'Main.swift'), str(folder/'Catalog.swift'), str(root/'Sources/TVCore/PlaybackResolution.swift'), str(root/'Tests/Standalone/FLVRenewal/CatalogSupport.swift'), str(root/'Tests/Standalone/FLVRenewal/CatalogCheck.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)

    # Formal pure regression tests also compile in their normal TVCoreTests layout.
    import shutil
    package = folder / 'package'
    source_dir = package / 'Sources/TVCore'
    test_dir = package / 'Tests/TVCoreTests'
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    (package / 'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "FLVFixture", platforms: [.macOS(.v14)], targets: [.target(name: "TVCore"), .testTarget(name: "TVCoreTests", dependencies: ["TVCore"])])\n')
    shutil.copy(folder / 'FLVLive.swift', source_dir)
    shutil.copy(root / 'Tests/Standalone/FLVRenewal/Support.swift', source_dir)
    shutil.copy(root / 'Tests/Standalone/FLVRenewal/CatalogSupport.swift', source_dir)
    shutil.copy(root / 'Sources/TVCore/PlaybackResolution.swift', source_dir)
    (source_dir / 'HTTPFixture.swift').write_text(main[:main.index('actor Resolver {')])
    shutil.copy(root / 'Tests/TVCoreTests/FLVRenewalTests.swift', test_dir)
    subprocess.run(['swift', 'test', '--package-path', str(package), '--jobs', '2'], check=True)
