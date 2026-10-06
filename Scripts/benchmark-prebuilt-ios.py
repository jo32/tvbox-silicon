#!/usr/bin/env python3
"""Controlled simulator benchmark; requires packaged Apple runtime and built Java host.

1. prepare <source-request.json>: generate Mac lazy conversion artifacts in a fresh work dir.
2. No arguments: build the dedicated app with the original plugin and converted artifacts.
3. Install/launch com.tvbox.yingxia.PrebuiltBenchmark via simctl; pass -prebuilt for seeding.
4. collect <unique-run-name> <simulator-udid>: save response, timing, logs and RSS samples.
Uninstall only this dedicated benchmark app before each measured cold launch. Both modes
bundle the same original plugin, excluding download time. Prebuilt is a traced home subset,
not an assertion that all plugin classes/features were converted. Check conversion logs.
"""
import json, pathlib, plistlib, shutil, subprocess, sys, time

def collect(mode, device):
    work = pathlib.Path(__file__).resolve().parent.parent / "build/prebuilt-benchmark"
    dest = work / mode
    dest.mkdir(parents=True, exist_ok=False)
    bundle = "com.tvbox.yingxia.PrebuiltBenchmark"
    container = pathlib.Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, bundle, "data"], text=True).strip())
    cache = container / "Library/Caches"
    samples = []
    start = time.monotonic()
    while time.monotonic() - start < 900:
        processes = subprocess.run(["pgrep", "-f", "PrebuiltBenchmark.app/PrebuiltBenchmark"], capture_output=True, text=True)
        for pid in processes.stdout.split():
            rss = subprocess.run(["ps", "-o", "rss=", "-p", pid], capture_output=True, text=True).stdout.strip()
            if rss.isdigit():
                samples.append({"elapsed": time.monotonic()-start, "pid": int(pid), "rssKiB": int(rss)})
        if (cache / "metrics.json").exists():
            break
        time.sleep(1)
    for name in ["metrics.json", "result.txt", "embedded-jvm.log", "seed-error.txt"]:
        if (cache / name).exists():
            shutil.copy2(cache / name, dest / name)
    (dest / "rss-samples.json").write_text(json.dumps(samples))
    if not (dest / "metrics.json").exists():
        raise SystemExit("Timed out; evidence saved. Terminate the benchmark app before retrying.")
    print((dest / "metrics.json").read_text())
    print("Sampled max RSS MiB:", max((s["rssKiB"] for s in samples), default=0)/1024)

if len(sys.argv) > 1 and sys.argv[1] == "collect":
    collect(sys.argv[2], sys.argv[3])
    raise SystemExit(0)
ROOT = pathlib.Path(__file__).resolve().parent.parent
WORK = ROOT / 'build/prebuilt-benchmark'
if len(sys.argv) > 1 and sys.argv[1] == "prepare":
    WORK.mkdir(parents=True, exist_ok=True)
    if (WORK / "converted").exists():
        raise SystemExit("Use a fresh build/prebuilt-benchmark directory to avoid reusing conversion results.")
    request = json.loads(pathlib.Path(sys.argv[2]).read_text())
    request.update(cache=str(WORK / "mac"), conversionCache=str(WORK / "converted"), params={})
    (WORK / "mac").mkdir(exist_ok=True)
    (WORK / "request.json").write_text(json.dumps(request))
    with (WORK / "mac-result.json").open("w") as output, (WORK / "mac.log").open("w") as log:
        subprocess.run([str(ROOT / "build/JavaHost/jre/bin/java"), "-Dtvbox.lazyDex=true", "-cp", str(ROOT / "build/JavaHost/host.jar") + ":" + str(ROOT / "build/JavaHost/lib/*"), "tvbox.runtime.NativeProbe", str(WORK / "request.json")], stdout=output, stderr=log, check=True, timeout=300)
    envelope = json.loads((WORK / "mac-result.json").read_text())
    if "error" in envelope:
        raise SystemExit(envelope["error"])
    print("Mac home items:", len(json.loads(envelope["result"]).get("list", [])))
    raise SystemExit(0)
APP = WORK / 'PrebuiltBenchmark.app'
OUT = ROOT / 'build/AppleRuntime/iphonesimulator'
APP.mkdir(parents=True, exist_ok=True)
for source, target in [(OUT/'Resources/lib', APP/'lib'), (OUT/'Resources/JavaHost', APP/'JavaHost'), (WORK/'converted', APP/'Preconverted')]:
    subprocess.run(['rsync','-a','--delete',str(source)+'/',str(target)+'/'],check=True)
shutil.copy2(ROOT/'build/JavaHost/host.jar',APP/'JavaHost/host.jar')
request=json.loads((WORK/'request.json').read_text())
shutil.copy2(request['jar'],APP/'plugin.jar')
(APP/'request.json').write_text(json.dumps(request))
source=(ROOT/'Runtime/AppleRuntime/Spike/main.m').read_text()
a=source.index('static void runJVM(void) {');b=source.index('@interface SpikeSceneDelegate',a)
source=source[:a]+r'''
extern char *TVAppleRuntimeRequest(const char *, const char *);
static void runJVM(void) {
 @autoreleasepool {
  NSString *cache=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
  NSString *bundle=NSBundle.mainBundle.bundlePath;
  NSString *converted=[cache stringByAppendingPathComponent:@"converted"];
  BOOL prebuilt=[NSProcessInfo.processInfo.arguments containsObject:@"-prebuilt"];
  NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
  if(prebuilt) {
   NSError *error=nil;
   if(![NSFileManager.defaultManager copyItemAtPath:[bundle stringByAppendingPathComponent:@"Preconverted"] toPath:converted error:&error]) {
    [error.description writeToFile:[cache stringByAppendingPathComponent:@"seed-error.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return;
   }
  }
  NSTimeInterval seeded=NSProcessInfo.processInfo.systemUptime;
  NSMutableDictionary *input=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"request.json"]] options:NSJSONReadingMutableContainers error:NULL] mutableCopy];
  input[@"session"]=@"benchmark"; input[@"jar"]=[bundle stringByAppendingPathComponent:@"plugin.jar"];
  input[@"cache"]=cache; input[@"conversionCache"]=converted; input[@"profile"]=[cache stringByAppendingPathComponent:@"profile"]; input[@"params"]=@{};
  NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:input options:0 error:NULL] encoding:NSUTF8StringEncoding];
  char *response=TVAppleRuntimeRequest(bundle.UTF8String,json.UTF8String);
  NSTimeInterval end=NSProcessInfo.processInfo.systemUptime;
  NSString *result=response ? @(response) : @"No result"; free(response);
  [result writeToFile:[cache stringByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  NSDictionary *metrics=@{@"prebuilt":@(prebuilt),@"seedSeconds":@(seeded-start),@"requestSeconds":@(end-seeded),@"totalSeconds":@(end-start),@"responseBytes":@([result lengthOfBytesUsingEncoding:NSUTF8StringEncoding])};
  [[NSJSONSerialization dataWithJSONObject:metrics options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[cache stringByAppendingPathComponent:@"metrics.json"] atomically:YES];
  dispatch_async(dispatch_get_main_queue(),^{[[NSNotificationCenter defaultCenter] postNotificationName:@"RuntimeResult" object:metrics.description];});
 }
}

''' + source[b:]
(WORK/'Benchmark.m').write_text(source)
info=dict(CFBundleIdentifier='com.tvbox.yingxia.PrebuiltBenchmark',CFBundleExecutable='PrebuiltBenchmark',CFBundleName='Prebuilt Benchmark',CFBundleVersion='1',CFBundleShortVersionString='1.0',CFBundlePackageType='APPL',MinimumOSVersion='17.0',UIDeviceFamily=[1],UILaunchScreen={},NSAppTransportSecurity={'NSAllowsArbitraryLoads':True},UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Runtime','UISceneDelegateClassName':'SpikeSceneDelegate'}]}})
(APP/'Info.plist').write_bytes(plistlib.dumps(info))
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
subprocess.run(['clang++','-target','arm64-apple-ios17.0-simulator','-isysroot',sdk,'-fobjc-arc','-I',str(OUT/'include'),str(WORK/'Benchmark.m'),str(ROOT/'Runtime/AppleRuntime/Native/AppleRuntime.m'),'-Wl,-force_load,'+str(OUT/'lib/libTVAppleRuntime.a'),'-Wl,-export_dynamic','-lz','-liconv','-framework','UIKit','-framework','Foundation','-framework','Security','-framework','CoreGraphics','-o',str(APP/'PrebuiltBenchmark')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(APP)],check=True)
print(APP)
