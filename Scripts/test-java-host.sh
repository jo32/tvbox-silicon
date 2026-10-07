#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 19)}"
mkdir -p build/host-tests
"$JDK/bin/javac" -cp 'build/JavaHost/host.jar:build/JavaHost/lib/*' -d build/host-tests Tests/Java/HostCompatibilityTest.java Tests/Java/PluginLoadingTest.java Tests/Java/CloudDriveBridgeTest.java Tests/Java/NativeLibrariesTest.java Tests/Java/PhiMemoryTest.java Tests/Java/LazyDexTest.java Tests/Java/HandlerLifetimeTest.java Tests/Java/PreparationProgressTest.java Tests/Java/ConversionResumeTest.java Tests/Java/RequestCancellationTest.java
"$JDK/bin/java" --add-opens java.base/java.lang=ALL-UNNAMED -Djava.io.tmpdir=/private/tmp -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' HostCompatibilityTest

"$JDK/bin/java" --add-opens java.base/java.lang=ALL-UNNAMED -Djava.io.tmpdir=/private/tmp -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' PluginLoadingTest

"$JDK/bin/java" -Dsun.net.http.allowRestrictedHeaders=true -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' CloudDriveBridgeTest

"$JDK/bin/java" -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' NativeLibrariesTest

"$JDK/bin/java" -Xmx128m -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' PhiMemoryTest

"$JDK/bin/java" -Xmx128m -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' LazyDexTest

"$JDK/bin/java" -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' HandlerLifetimeTest

"$JDK/bin/java" -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' PreparationProgressTest

"$JDK/bin/java" -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' ConversionResumeTest

"$JDK/bin/java" -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' RequestCancellationTest
