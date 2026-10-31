#!/usr/bin/env python3
"""Bundle private Dandanplay credentials for all Apple targets without logging them."""
import json
import os
from pathlib import Path
import plistlib

source = Path(os.environ.get("DANDANPLAY_CONFIG", Path.home() / ".config/yingxia/dandanplay.json"))
destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "DandanplayCredentials.plist"
if not source.is_file():
    # Prevent a previous build's credential surviving when configuration is removed.
    destination.unlink(missing_ok=True)
    print("warning: Dandanplay credentials are absent; official danmaku requests will be unavailable. See Docs/DANDANPLAY.md.")
else:
    config = json.loads(source.read_text())
    if any(not isinstance(config.get(key), str) or not config[key].strip() for key in ("appId", "appSecret")):
        raise SystemExit("Invalid Dandanplay configuration: appId and appSecret are required")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(plistlib.dumps({key: config[key] for key in ("appId", "appSecret")}))
    destination.chmod(0o600)
    print("Dandanplay API configuration embedded")
