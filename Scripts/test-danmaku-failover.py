#!/usr/bin/env python3
"""Run the existing custom danmaku suite plus failover regressions without native app dependencies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='danmaku-failover-') as temp:
    folder = Path(temp)
    (folder / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DanmakuFixture", platforms: [.macOS(.v14)], targets: [.target(name: "TVCore"), .testTarget(name: "TVCoreTests", dependencies: ["TVCore"])])
''')
    source = folder / 'Sources/TVCore'; source.mkdir(parents=True)
    tests = folder / 'Tests/TVCoreTests'; tests.mkdir(parents=True)
    for name in ['AutomaticDanmaku.swift','CatalogDanmaku.swift','DanmakuService.swift','DanmakuResolver.swift','DandanplayCredentials.swift','MediaCache.swift']:
        (source / name).symlink_to(root / 'Sources/TVCore' / name)
    models = (root / 'Sources/TVCore/Models.swift').read_text()
    web = models[models.index('public enum WebAddress {'):models.index('public enum SourceRuntime:')]
    (source / 'WebAddress.swift').write_text('import Foundation\n' + web)
    for name in ['CustomDanmakuTests.swift','DanmakuFailoverTests.swift']:
        (tests / name).symlink_to(root / 'Tests/TVCoreTests' / name)
    model = (root / 'App/CatalogDanmakuView.swift').read_text()
    (tests / 'CatalogDanmakuModel.swift').write_text('import Foundation\nimport Observation\n@testable import TVCore\n' +
        model[model.index('@MainActor @Observable final class CatalogDanmakuModel'):model.index('struct CatalogDanmakuSettingsView:')])
    danmaku = (root / 'Sources/TVCore/Danmaku.swift').read_text()
    (source / 'Display.swift').write_text('import Foundation\n' +
        danmaku[danmaku.index('public struct Danmaku:'):danmaku.index('public enum DanmakuSource')] +
        danmaku[danmaku.index('public enum DanmakuStyle'):danmaku.index('public enum DanmakuDensity')])
    (tests / 'ManualSelectionTests.swift').symlink_to(root / 'Tests/Standalone/Danmaku/ManualSelectionTests.swift')
    picker = model[model.index('struct CatalogDanmakuSettingsView:'):]
    actions = (picker[picker.index('    private func cancelWork('):picker.index('    private func resetSearch(')] +
        picker[picker.index('    private func perform('):picker.index('    private func search(')] +
        picker[picker.index('    private func load(_ episode:'):picker.rindex('}')])
    (tests / 'PickerActions.swift').write_text('import Foundation\n@testable import TVCore\nextension PickerFixture {\n' +
        actions.replace('private func ', 'func ') + '}\n')
    shutil.copy(root / 'Tests/Standalone/Danmaku/Support.swift', source)
    subprocess.run(['swift', 'test', '--package-path', str(folder), '--jobs', '2'], check=True)
