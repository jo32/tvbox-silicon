#!/bin/bash
# Refresh the Java host (host.jar and its libraries) in packaged Apple runtimes without rebuilding
# the native JVM. Run after Scripts/build-java-host.sh; Xcode copies the result into each app.
# Usage: Scripts/sync-apple-javahost.sh [platform...]   (default: every packaged platform)
set -euo pipefail
cd "$(dirname "$0")/.."
test -f build/JavaHost/host.jar || { echo "Run Scripts/build-java-host.sh first" >&2; exit 1; }
if [ $# -eq 0 ]; then
  set --
  for dir in build/AppleRuntime/*/; do [ -d "$dir/Resources/JavaHost" ] && set -- "$@" "$(basename "$dir")"; done
fi
for platform in "$@"; do
  OUT="build/AppleRuntime/$platform/Resources/JavaHost"
  mkdir -p "$OUT/lib"
  cp build/JavaHost/host.jar "$OUT/"
  # Strip embedded desktop executables from dependencies; Apple uses static JNI.
  python3 - "$OUT/lib" <<'PY'
import pathlib,sys,zipfile
out=pathlib.Path(sys.argv[1])
sources={source.name for source in pathlib.Path('build/JavaHost/lib').glob('*.jar')}
for stale in out.glob('*.jar'):
 if stale.name not in sources: stale.unlink()
for source in pathlib.Path('build/JavaHost/lib').glob('*.jar'):
 with zipfile.ZipFile(source) as src, zipfile.ZipFile(out/source.name,'w',zipfile.ZIP_DEFLATED) as dst:
  for entry in src.infolist():
   if entry.filename.startswith('natives/') or entry.filename.endswith(('.dylib','.jnilib','.dll')): continue
   if entry.filename.endswith('.so') and not entry.filename.startswith('android/'): continue
   dst.writestr(entry,src.read(entry))
PY
  echo "Synced Java host: $OUT"
done
