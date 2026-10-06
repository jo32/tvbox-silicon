#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; TARGET="${1:-ios-simulator}"
case "$TARGET" in
 ios-simulator) PLATFORM=iphonesimulator; TRIPLE=arm64-apple-ios17.0-simulator; FAMILY=1 ;;
 tvos-simulator) PLATFORM=appletvsimulator; TRIPLE=arm64-apple-tvos17.0-simulator; FAMILY=3 ;;
 *) exit 2 ;;
esac
OUT="$ROOT/build/AppleRuntime/$PLATFORM"
APP="$ROOT/build/apple-runtime/EmbeddedHostTest-$TARGET.app"
mkdir -p "$APP"
rsync -a "$OUT/Resources/lib/" "$APP/lib/"
rsync -a --delete "$OUT/Resources/JavaHost/" "$APP/JavaHost/"
cp build/JavaHost/host.jar "$APP/JavaHost/host.jar"
cp build/runtime-audit/downloads/ce647a3d82a319476b0bf0f138ebbdd05105e5a149dda8b3ca3a5d37d83e5cac "$APP/plugin.jar"
cp build/on-device-baseline/01/source-08549fcc1b/request.json "$APP/request.json"
python3 - "$APP" "$FAMILY" <<'PY'
import pathlib,sys,plistlib
app=pathlib.Path(sys.argv[1])
s=pathlib.Path('Runtime/AppleRuntime/Spike/main.m').read_text()
a=s.index('static void runJVM(void) {');b=s.index('@interface SpikeSceneDelegate',a)
s=s[:a]+'''extern char *TVAppleRuntimeRequest(const char *, const char *);
static void runJVM(void) {
 @autoreleasepool {
  NSString *cache=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
  freopen([[cache stringByAppendingPathComponent:@"embedded.log"] UTF8String],"w",stdout); dup2(fileno(stdout),fileno(stderr)); setbuf(stdout,NULL); setbuf(stderr,NULL);
  NSString *bundle=NSBundle.mainBundle.bundlePath;
  NSMutableDictionary *input=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"request.json"]] options:NSJSONReadingMutableContainers error:NULL] mutableCopy];
  input[@"session"]=@"guard-test"; input[@"jar"]=[bundle stringByAppendingPathComponent:@"plugin.jar"]; input[@"cache"]=cache; input[@"conversionCache"]=cache; input[@"profile"]=[cache stringByAppendingPathComponent:@"profile"]; input[@"params"]=@{};
  NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:input options:0 error:NULL] encoding:NSUTF8StringEncoding];
  char *response=TVAppleRuntimeRequest(bundle.UTF8String,json.UTF8String);
  NSString *result=response ? @(response) : @"No result"; free(response);
  [result writeToFile:[cache stringByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  NSLog(@"%@",result);
  dispatch_async(dispatch_get_main_queue(),^{[[NSNotificationCenter defaultCenter] postNotificationName:@"RuntimeResult" object:result];});
 }
}

''' + s[b:]
(app.parent/'EmbeddedTestMain.m').write_text(s)
info=dict(CFBundleIdentifier='com.tvbox.yingxia.EmbeddedHostTest',CFBundleExecutable='EmbeddedHostTest',CFBundleName='Embedded Host Test',CFBundleVersion='1',CFBundleShortVersionString='1.0',CFBundlePackageType='APPL',MinimumOSVersion='17.0',UIDeviceFamily=[int(sys.argv[2])],UILaunchScreen={},UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Runtime','UISceneDelegateClassName':'SpikeSceneDelegate'}]}})
(app/'Info.plist').write_bytes(plistlib.dumps(info))
PY
clang++ -target "$TRIPLE" -isysroot "$(xcrun --sdk "$PLATFORM" --show-sdk-path)" -fobjc-arc -I "$OUT/include" \
 build/apple-runtime/EmbeddedTestMain.m Runtime/AppleRuntime/Native/AppleRuntime.m \
 -Wl,-force_load,"$OUT/lib/libTVAppleRuntime.a" -Wl,-export_dynamic -lz -liconv -framework UIKit -framework Foundation -framework Security -framework CoreGraphics -o "$APP/EmbeddedHostTest"
codesign --force --sign - "$APP"
echo "$APP"
