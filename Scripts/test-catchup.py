#!/usr/bin/env python3
"""Run catchup production models/parsing/renderer in a small package, without native media dependencies."""
from pathlib import Path
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


support = '''import Foundation
public struct ExternalSubtitle: Hashable, Sendable {}
public struct PlaybackSkip: Hashable, Sendable {}
public enum BilibiliAPI { public struct Part: Hashable, Sendable {} }
public struct PlaybackHistoryContext: Codable, Hashable, Sendable {}
enum L10n { static func text(_ value: String, _ arguments: CVarArg...) -> String { value } }
enum LoadedLivePlugin { static func inflate(_ data: Data, format: String) -> Data? { nil } }
struct HTTPClient: Sendable {
 func get(_ url: URL, limit: Int = 20000000) async throws -> (Data, URL) {
  let (data, response) = try await URLSession.shared.data(from: url)
  guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
  return (data, response.url ?? url)
 }
}
'''
models = (ROOT / 'Sources/TVCore/Models.swift').read_text()
for marker in ['public enum TVError:', 'public enum WebAddress', 'public struct ChannelLine:', 'public struct Channel:']:
    support += declaration(models, marker) + '\n'


class FixtureHTTP(BaseHTTPRequestHandler):
    paths = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.paths.append(self.path)
        route = urlsplit(self.path)
        status = 200
        if route.path == '/guide.xml':
            start = datetime.now(timezone.utc) - timedelta(days=2)
            stamp = lambda value: value.strftime('%Y%m%d%H%M%S +0000')
            body = ('<tv><channel id="News"><display-name>News</display-name></channel>'
                    '<programme channel="News" start="' + stamp(start) + '" stop="' + stamp(start + timedelta(hours=1))
                    + '"><title>Two days ago</title></programme></tv>')
        elif route.path == '/epg/News':
            date = parse_qs(route.query)['date'][0]
            body = '{"epg_data":[{"start":"08:00","end":"09:00","title":"' + date + '"}]}'
        elif route.path == '/replay/index.m3u8' and route.query.startswith('sig=live%2F%2b+A&begin=') and '&end=' in route.query:
            body = '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n'
        else:
            status = 400
            body = 'unexpected request'
        data = body.encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


with tempfile.TemporaryDirectory(prefix='tvbox-catchup-') as directory:
    folder = Path(directory)
    sources = folder / 'Sources/TVCore'
    tests = folder / 'Tests/TVCoreTests'
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    (folder / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CatchupChecks", platforms: [.macOS(.v14)], targets: [.target(name: "TVCore"), .testTarget(name: "TVCoreTests", dependencies: ["TVCore"])])
''')
    (sources / 'Models.swift').write_text(support)
    for name in ['Playlist.swift', 'ProgramGuide.swift', 'LiveLineup.swift', 'ProgramCatchup.swift']:
        path = ROOT / 'Sources/TVCore' / name
        if path.exists():
            (sources / name).write_text(path.read_text())
    (tests / 'CatchupTests.swift').write_text((ROOT / 'Tests/TVCoreTests/CatchupTests.swift').read_text())
    server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHTTP)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        environment = dict(os.environ, CATCHUP_TEST_SERVER='http://127.0.0.1:' + str(server.server_port))
        subprocess.run(['swift', 'test', '--package-path', str(folder), '--jobs', '2'], env=environment, check=True)
        assert FixtureHTTP.paths.count('/guide.xml') == 2, 'expanded history did not reload the short-window cache'
        assert '/epg/News?date=2023-11-15' in FixtureHTTP.paths, 'historical DIYP request used today'
        assert any(path.startswith('/replay/index.m3u8?sig=live%2F%2b+A&begin=') for path in FixtureHTTP.paths), 'signed replay never reached HTTP'
        print('PASS: local HTTP XMLTV history/cache expansion, requested DIYP day, signed finite replay request')
    finally:
        server.shutdown()
        server.server_close()
