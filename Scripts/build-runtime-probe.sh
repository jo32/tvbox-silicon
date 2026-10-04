#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Regenerating this fixture requires JDK 17+ and Google's D8 compiler.
# The fixture is bundled; the separate Mac plugin host bundles its own JRE.
TVBOX_JDK="${TVBOX_JDK:-$(/usr/libexec/java_home)}"
TVBOX_D8="${TVBOX_D8:-build/tools/r8lib.jar}"
mkdir -p build/probe/classes build/probe/dex
"$TVBOX_JDK/bin/javac" --release 8 -d build/probe/classes Tests/Java/RuntimeProbe.java
"$TVBOX_JDK/bin/java" -cp "$TVBOX_D8" com.android.tools.r8.D8 --release --min-api 21 --output build/probe/dex build/probe/classes/tvbox/RuntimeProbe.class
python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
raw = Path('build/probe/dex/classes.dex').read_bytes()
for target in ['Tests/TVCoreTests/Fixtures/runtime-probe.jar', 'App/Resources/runtime-probe.jar']:
    with ZipFile(target, 'w', ZIP_DEFLATED) as archive:
        entry = ZipInfo('classes.dex', (2026, 1, 1, 0, 0, 0))
        entry.compress_type = ZIP_DEFLATED
        archive.writestr(entry, raw)
PY
