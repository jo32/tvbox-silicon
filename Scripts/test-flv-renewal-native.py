#!/usr/bin/env python3
"""Loopback FLV reconnect vs uninterrupted fMP4. Requires ffmpeg, ffprobe and host TVCore dependencies."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def build_driver(folder):
    (folder / "Sources").mkdir()
    shutil.copy(ROOT / "Tests/Standalone/FLVRenewal/Native.swift", folder / "Sources")
    (folder / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "FLVCheck", platforms: [.macOS(.v14)], '
        f'dependencies: [.package(name: "Core", path: {json.dumps(str(ROOT))})], '
        'targets: [.executableTarget(name: "FLVCheck", dependencies: [.product(name: "TVCore", package: "Core")], path: "Sources")])\n'
    )
    subprocess.run(["swift", "build", "--package-path", folder, "--product", "FLVCheck"], check=True)
    output = subprocess.check_output(["swift", "build", "--package-path", folder, "--show-bin-path"], text=True)
    return Path(output.strip()) / "FLVCheck"


def response_builder(folder):
    file = folder / "source.flv"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", ROOT / "Tests/TVCoreTests/Fixtures/remux-long.mkv",
                    "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-t", "18", "-f", "flv", file], check=True)
    wire = file.read_bytes()
    offset = 13
    configs, tags = wire[:offset], []
    while offset < len(wire):
        size = int.from_bytes(wire[offset + 1:offset + 4], "big")
        tag = wire[offset:offset + size + 15]
        assert len(tag) == size + 15
        if tag[0] in (8, 9):
            if tag[12] == 0:
                configs += tag
            elif tag[12] == 1:
                tags.append((int.from_bytes(tag[7:8] + tag[4:7], "big"), tag))
        offset += len(tag)

    def response(start, end, torn=False):
        body = configs + b"".join(tag for time, tag in tags if start <= time < end)
        return body + (next(tag for time, tag in tags if time >= end)[:13] if torn else b"")
    return response


def packets(file, track):
    result = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", str(track), "-show_packets",
                                      "-show_data_hash", "sha256", "-show_entries", "packet=pts_time,dts_time,data_hash", "-of", "json", file])
    return [(row["data_hash"], row["dts_time"], row["pts_time"]) for row in json.loads(result)["packets"]]


def exercise(driver, folder, mode, bodies, maps):
    requests, resolutions = [], []

    class Origin(BaseHTTPRequestHandler):
        def log_message(self, *args): pass

        def do_GET(self):
            if self.path == "/resolve":
                resolutions.append(1)
                body, status = str(len(resolutions)).encode(), 200
            else:
                index = len(requests)
                valid = self.path == f"/{index}.flv" and self.headers.get("X-Generation") == str(index) and "Range" not in self.headers
                requests.append(valid)
                body, status = (bodies[index], 200) if valid and index < len(bodies) else (b"", 410)
            self.send_response(status)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            for offset in range(0, len(body), 509):
                self.wfile.write(body[offset:offset + 509])

    dest = folder / mode
    dest.mkdir()
    with ThreadingHTTPServer(("127.0.0.1", 0), Origin) as server:
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            subprocess.run([driver, f"http://127.0.0.1:{server.server_port}", dest, mode], timeout=25, check=True)
        finally:
            server.shutdown()
            worker.join()
    assert all(requests) and len(resolutions) == (0 if mode == "control" else len(bodies))
    assert len(requests) == len(resolutions) + 1
    tracks, boundaries = [], []
    for track in (0, 1):
        lines = (dest / f"{track}.m3u8").read_text().splitlines()
        assert "#EXT-X-ENDLIST" in lines and "#EXT-X-MEDIA-SEQUENCE:0" in lines and "#EXT-X-DISCONTINUITY-SEQUENCE:0" in lines
        assert sum(line.startswith("#EXT-X-MAP:") for line in lines) == maps and lines.count("#EXT-X-DISCONTINUITY") == maps - 1
        boundaries.append([line.replace(f'"{track}-', '"').removeprefix(f"{track}-") for line in lines])
        tracks.append([packet for line in lines if line.endswith(".m4s") for packet in packets(dest / (line + ".mp4"), 0)])
    assert boundaries[0] == boundaries[1], f"{mode}: audio/video boundary mismatch"
    print(f"{mode}: responses={len(requests)}, maps={maps}, video={len(tracks[0])}, audio={len(tracks[1])}", flush=True)
    return tracks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, help="prebuilt Native.swift fixture executable")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="flv-native-") as temp:
        folder = Path(temp)
        driver = args.driver.resolve() if args.driver else build_driver(folder)
        response = response_builder(folder)
        end = 15_000
        whole = response(0, end)
        input_file = folder / "control.flv"
        input_file.write_bytes(whole)
        control = exercise(driver, folder, "control", [whole], 1)
        for track in (0, 1):
            assert control[track] and [row[0] for row in control[track]] == [row[0] for row in packets(input_file, track)]
        cases = [
            ("overlap", [response(0, 4100, True), response(0, 9800, True), response(6000, end)], 3),
            ("disjoint", [response(0, 6000), response(6000, 12000), response(12000, end)], 3),
            ("early", [response(0, 1600, True), response(0, 900, True), whole], 1),
        ]
        for mode, bodies, maps in cases:
            assert exercise(driver, folder, mode, bodies, maps) == control, f"{mode}: ordered payloads, DTS or PTS differ"
    print("PASS: all available A/V packets and timestamps match uninterrupted remux")


if __name__ == "__main__":
    main()
