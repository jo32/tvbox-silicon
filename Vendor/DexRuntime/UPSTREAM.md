# Experimental DEX engine

Source: https://github.com/speedyfriend433/DexLoom
Commit: 4a11089cb6a1377cbf437ebccd24468296357132
License: MIT (LICENSE retained).

Core/ is the upstream C implementation. TVJarRuntime.c is our serialized, bounded bridge.
No JIT is enabled. This is not a JVM, Android OS, or complete CatVod implementation.
The bridge currently executes parameterless static DEX methods returning int for runtime validation only.
Android native libraries are detected and refused before execution. Do not report a loaded JAR as a working source.
