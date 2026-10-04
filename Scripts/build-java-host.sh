#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 19)}"
MAVEN="${MAVEN_BIN:-$PWD/build/tools/apache-maven-3.9.9/bin/mvn}"
if [ ! -x "$MAVEN" ]; then MAVEN="$(command -v mvn)"; fi
"$MAVEN" -q -f Runtime/JavaHost/pom.xml package dependency:copy-dependencies -DoutputDirectory=target/lib
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
if [ ! -x "$DEST/jre/bin/java" ] || ! "$DEST/jre/bin/java" --list-modules | grep -q '^jdk.httpserver@'; then
  if [ -d "$DEST/jre" ]; then mv "$DEST/jre" "$PWD/build/JavaHost-jre.previous.$$"; fi
  "$JDK/bin/jlink" --add-modules java.base,java.logging,java.xml,java.desktop,java.management,java.naming,jdk.unsupported,jdk.crypto.ec,jdk.zipfs,jdk.httpserver --strip-debug --no-header-files --no-man-pages --output "$DEST/jre"
fi
