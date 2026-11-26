#!/usr/bin/env python3
"""Focused production EPG model/HTTP tests; needs Swift 6, no app/native media build.

The temporary package uses the production guide sources and request tests. The
unrelated Channel/WebAddress/gzip dependencies are small test substitutes; these
checks exercise plain XML/JSON over real loopback HTTP, not gzip inflation.
"""
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

class Handler(http.server.BaseHTTPRequestHandler):
    counts = {}
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]
        self.counts[path] = self.counts.get(path, 0) + 1
        if path in ['/same', '/cross', '/return']:
            dest = {'/same': f'http://127.0.0.1:{self.server.server_port}/echo',
                    '/cross': f'http://localhost:{self.server.server_port}/return',
                    '/return': f'http://127.0.0.1:{self.server.server_port}/echo'}[path]
            self.send_response(302)
            self.send_header('Location', dest)
            self.end_headers()
            return
        if path == '/failure':
            self.send_response(503)
            self.end_headers()
            return
        if path in ['/epg', '/uncached-epg']:
            title = str(self.counts[path]) if path == '/uncached-epg' else '|'.join(self.headers.get(k, '') for k in ['Authorization', 'Cookie'])
            body = ('{"epg_data":[{"start":"08:00","end":"09:00","title":"' + title + '"}]}').encode()
        elif path == '/named-epg':
            name = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get('name', [''])[0]
            body = b'{"epg_data":[{"start":"08:00","end":"09:00","title":"Named News Bulletin"}]}' if name == 'News' else b'{"epg_data":[]}'
        elif path == '/guide.xml':
            auth = self.headers.get('Authorization', '')
            number = self.counts[path]
            body = (f'<tv><channel id="news"><display-name>News</display-name></channel><programme channel="news" start="20261114080000 +0000" stop="20261114090000 +0000"><title>{auth}-{number}</title></programme><programme channel="news" start="20261115080000 +0000" stop="20261115090000 +0000"><title>next-{number}</title></programme></tv>').encode()
        elif path == '/echo':
            body = '|'.join(self.headers.get(k, '') for k in ['Authorization', 'Cookie', 'X-API-Key', 'User-Agent']).encode()
        elif path == '/failure-count':
            body = str(self.counts.get('/failure', 0)).encode()
        else:
            body = b'x' * (4096 if 'large' in path else 1)
        self.send_response(200)
        if path in ['/no-store', '/uncached-epg']:
            self.send_header('Cache-Control', 'no-store')
        if path != '/chunked-large':
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

with Server(('127.0.0.1', 0), Handler) as server, tempfile.TemporaryDirectory(prefix='guide-requests-') as temporary:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = Path(temporary)
    (root / 'Sources/TVCore').mkdir(parents=True)
    (root / 'Tests/TVCoreTests').mkdir(parents=True)
    (root / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GuideRequests", platforms: [.macOS(.v14)], targets: [.target(name: "TVCore"), .testTarget(name: "TVCoreTests", dependencies: ["TVCore"])])
''')
    for name in ['ProgramGuide.swift', 'GuideRequest.swift']:
        (root / 'Sources/TVCore' / name).symlink_to(ROOT / 'Sources/TVCore' / name)
    (root / 'Sources/TVCore/Support.swift').write_text('''import Foundation
public struct Channel: Sendable { public var name: String; public var guideID: String?; public init(name: String, url: URL) { self.name = name } }
public struct LiveSource { public var url: URL; public var guide: String? }
public struct Diagnostics: Sendable { public static let shared = Diagnostics(); public enum Level { case warning }; public func record(_ level: Level, _ area: String, _ text: String) {} }
enum TVError: Error { case invalidConfiguration }
enum LoadedLivePlugin { static func inflate(_ data: Data, format: String) -> Data? { nil } }
enum WebAddress { static func resolve(_ text: String, relativeTo url: URL?) throws -> URL { URL(string: text, relativeTo: url)!.absoluteURL } }
''')
    (root / 'Tests/TVCoreTests/ProgramGuideRequestTests.swift').symlink_to(ROOT / 'Tests/TVCoreTests/ProgramGuideRequestTests.swift')
    source = (ROOT / 'App/LiveGuide.swift').read_text()
    controller = source[source.index('@MainActor @Observable final class LiveGuide'):source.index('\n/// Redraws a programme line')]
    (root / 'Tests/TVCoreTests/LiveGuideUnderTest.swift').write_text('import SwiftUI\nimport TVCore\n@MainActor @Observable final class Store { var guideAddresses: [String: String] = [:] }\n' + controller)
    (root / 'Tests/TVCoreTests/LiveGuideRequest.swift').symlink_to(ROOT / 'Tests/TVCoreTests/Fixtures/LiveGuideRequest.swift')
    env = dict(os.environ, GUIDE_HTTP_FIXTURE=f'http://127.0.0.1:{server.server_port}')
    subprocess.run(['swift', 'test', '--package-path', str(root)], check=True, env=env)
    server.shutdown()
