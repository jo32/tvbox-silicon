#!/usr/bin/env python3
"""Run real history/writer code with a delayed disk boundary; no app/native dependencies."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='history-regression-') as temp:
    folder = Path(temp)
    files = []
    for name in ['PlaybackHistory.swift', 'PlaybackHistoryPersistence.swift']:
        source = root / 'Sources/TVCore' / name
        if not source.exists():
            continue
        body = source.read_text().replace('try data.write(to: file, options: .atomic)', 'try WriteProbe.beforeWrite(); try data.write(to: file, options: .atomic)')
        if name == 'PlaybackHistory.swift' and 'func flushPersistence()' not in body:
            body += '\nextension PlaybackHistory { func flushPersistence() async -> Bool { persistenceError == nil } }\n'
        target = folder / name
        target.write_text(body)
        files.append(str(target))
    files += [str(p) for p in sorted((root / 'Tests/Standalone/HistoryPersistence').glob('*.swift'))]
    binary = folder / 'check'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', *files, '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
