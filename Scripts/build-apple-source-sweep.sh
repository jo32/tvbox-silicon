#!/bin/bash
# Build SourceSweep, a simulator app that runs plugin requests through the same embedded runtime
# as the app (TVAppleRuntimeRequest), so Scripts/test-sources.py --apple-simulator can test every
# source on Apple's JVM, interpreter and platform limits instead of the desktop host.
# It serves Library/Caches/sweep/inbox/<id>.json and answers in outbox/<id>.json; the runtime's
# stdout goes to sweep/stdout.log and stderr to embedded-jvm.log.
# Usage: Scripts/build-apple-source-sweep.sh [tvos-simulator|ios-simulator]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; TARGET="${1:-tvos-simulator}"
case "$TARGET" in
 ios-simulator) PLATFORM=iphonesimulator; TRIPLE=arm64-apple-ios17.0-simulator; FAMILY=1 ;;
 tvos-simulator) PLATFORM=appletvsimulator; TRIPLE=arm64-apple-tvos17.0-simulator; FAMILY=3 ;;
 *) echo "Unknown target $TARGET" >&2; exit 2 ;;
esac
OUT="$ROOT/build/AppleRuntime/$PLATFORM"
WORK="$ROOT/build/apple-runtime"
APP="$WORK/SourceSweep-$TARGET.app"
mkdir -p "$APP"
rsync -a "$OUT/Resources/lib/" "$APP/lib/"
rsync -a --delete "$OUT/Resources/JavaHost/" "$APP/JavaHost/"
python3 - "$APP" "$FAMILY" "$WORK/SourceSweepMain.m" <<'PY'
import pathlib,sys,plistlib
app,family,main=pathlib.Path(sys.argv[1]),int(sys.argv[2]),pathlib.Path(sys.argv[3])
s=pathlib.Path('Runtime/AppleRuntime/Spike/main.m').read_text()
a=s.index('static void runJVM(void) {');b=s.index('@interface SpikeSceneDelegate',a)
s=s[:a]+r'''extern char *TVAppleRuntimeRequest(const char *, const char *);
static void runJVM(void) {
 @autoreleasepool {
  NSFileManager *files=NSFileManager.defaultManager;
  NSString *sweep=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"sweep"];
  NSString *inbox=[sweep stringByAppendingPathComponent:@"inbox"], *outbox=[sweep stringByAppendingPathComponent:@"outbox"];
  [files createDirectoryAtPath:inbox withIntermediateDirectories:YES attributes:nil error:NULL];
  [files createDirectoryAtPath:outbox withIntermediateDirectories:YES attributes:nil error:NULL];
  freopen([sweep stringByAppendingPathComponent:@"stdout.log"].UTF8String,"a",stdout); setbuf(stdout,NULL);
  NSString *bundle=NSBundle.mainBundle.bundlePath;
  NSMutableSet *started=[NSMutableSet set];
  [@"ready" writeToFile:[sweep stringByAppendingPathComponent:@"ready"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  for (;;) {
   for (NSString *name in [files contentsOfDirectoryAtPath:inbox error:NULL]) {
    if (![name hasSuffix:@".json"] || [started containsObject:name]) continue;
    [started addObject:name];
    NSString *json=[NSString stringWithContentsOfFile:[inbox stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:NULL];
    if (!json) continue;
    // Like the app's plugin workers: one large-stack thread per request.
    NSThread *thread=[[NSThread alloc] initWithBlock:^{
     char *response=TVAppleRuntimeRequest(bundle.UTF8String,json.UTF8String);
     NSString *result=response ? @(response) : @"{\"error\":\"The plugin runtime returned no response.\"}"; free(response);
     NSString *partial=[outbox stringByAppendingPathComponent:[name stringByAppendingString:@".part"]];
     [result writeToFile:partial atomically:NO encoding:NSUTF8StringEncoding error:NULL];
     [files moveItemAtPath:partial toPath:[outbox stringByAppendingPathComponent:name] error:NULL];
     [files removeItemAtPath:[inbox stringByAppendingPathComponent:name] error:NULL];
    }];
    thread.stackSize=16*1024*1024; [thread start];
   }
   usleep(100000);
  }
 }
}

'''+s[b:]
main.write_text(s)
info=dict(CFBundleIdentifier='com.tvbox.yingxia.SourceSweep',CFBundleExecutable='SourceSweep',CFBundleName='Source Sweep',CFBundleVersion='1',CFBundleShortVersionString='1.0',CFBundlePackageType='APPL',MinimumOSVersion='17.0',UIDeviceFamily=[family],UILaunchScreen={},NSAppTransportSecurity={'NSAllowsArbitraryLoads':True},UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Runtime','UISceneDelegateClassName':'SpikeSceneDelegate'}]}})
(app/'Info.plist').write_bytes(plistlib.dumps(info))
PY
clang++ -target "$TRIPLE" -isysroot "$(xcrun --sdk "$PLATFORM" --show-sdk-path)" -fobjc-arc -I "$OUT/include" \
 "$WORK/SourceSweepMain.m" Runtime/AppleRuntime/Native/AppleRuntime.m \
 -Wl,-force_load,"$OUT/lib/libTVAppleRuntime.a" -Wl,-export_dynamic -lc++ -lz -liconv -framework UIKit -framework Foundation -framework Security -framework CoreGraphics -o "$APP/SourceSweep"
codesign --force --sign - "$APP"
echo "$APP"
