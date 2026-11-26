#!/usr/bin/env python3
"""Compile the production cast controller and SOAP/relay code against a local TCP renderer.

Only Observation/UI imports, logging/localization and already-resolved media are substituted.
The controller body and network implementation are used directly from this checkout.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="cast-cancellation-") as directory:
    output = Path(directory)
    source = (root / "App/DLNACast.swift").read_text()
    controller = source[source.index("@MainActor @Observable final class CastController"):source.index("\n/// What a TV is given")]
    controller = controller.replace("@Observable ", "").replace("@ObservationIgnored ", "")
    (output / "Controller.swift").write_text("import Foundation\n" + controller)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    str(root / "Sources/TVCore/DLNA.swift"), str(root / "Sources/TVCore/CastRelay.swift"),
                    str(output / "Controller.swift"), str(root / "Tests/TVCoreTests/Fixtures/CastCancellation.swift"),
                    "-o", str(output / "checks")], check=True)
    subprocess.run([str(output / "checks")], check=True, timeout=45)
