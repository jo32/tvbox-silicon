#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 19)}"
MAVEN="${MAVEN_BIN:-$PWD/build/tools/apache-maven-3.9.9/bin/mvn}"
if [ ! -x "$MAVEN" ]; then MAVEN="$(command -v mvn)"; fi
"$MAVEN" -q -f Runtime/JavaHost/pom.xml package dependency:copy-dependencies -DoutputDirectory=target/lib
# sardine-android (WebDAV) is published only as an Android AAR. Its classes are plain JVM
# bytecode, so pin the archive and add its classes.jar to the host libraries.
SARDINE="$PWD/build/tools/sardine-android-0.9.aar"
SARDINE_SHA256=6501973e47061e5de4a24d222fb1b459dd26ad3e02631afa06ecda45b7fd2dde
if [ ! -f "$SARDINE" ] || [ "$(shasum -a 256 "$SARDINE" | cut -d' ' -f1)" != "$SARDINE_SHA256" ]; then
  mkdir -p "$(dirname "$SARDINE")"
  curl -fsSL -o "$SARDINE.tmp" https://jitpack.io/com/github/thegrizzlylabs/sardine-android/0.9/sardine-android-0.9.aar
  [ "$(shasum -a 256 "$SARDINE.tmp" | cut -d' ' -f1)" = "$SARDINE_SHA256" ] || { echo "sardine-android checksum mismatch" >&2; exit 1; }
  mv -f "$SARDINE.tmp" "$SARDINE"
fi
unzip -p "$SARDINE" classes.jar > Runtime/JavaHost/target/lib/sardine-android-0.9.jar
DEST="$PWD/build/JavaHost"
mkdir -p "$DEST/lib"
# Existing source sessions may still be reading these archives. Replace atomically.
cp Runtime/JavaHost/target/local-jar-host-0.1.0.jar "$DEST/host.jar.$$.tmp"
mv -f "$DEST/host.jar.$$.tmp" "$DEST/host.jar"
for library in Runtime/JavaHost/target/lib/*.jar; do
  target="$DEST/lib/$(basename "$library")"
  cp "$library" "$target.$$.tmp"
  mv -f "$target.$$.tmp" "$target"
done
# jdk.charsets carries GBK/GB2312, which many Chinese source sites still serve.
if [ ! -x "$DEST/jre/bin/java" ] || ! "$DEST/jre/bin/java" --list-modules | grep -q '^jdk.httpserver@' || ! "$DEST/jre/bin/java" --list-modules | grep -q '^jdk.charsets@'; then
  if [ -d "$DEST/jre" ]; then mv "$DEST/jre" "$PWD/build/JavaHost-jre.previous.$$"; fi
  "$JDK/bin/jlink" --add-modules java.base,java.logging,java.xml,java.desktop,java.management,java.naming,jdk.unsupported,jdk.crypto.ec,jdk.zipfs,jdk.httpserver,jdk.charsets --strip-debug --no-header-files --no-man-pages --output "$DEST/jre"
fi
