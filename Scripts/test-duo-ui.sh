#!/bin/bash
# 真机/模拟器验收：用 XCUITest 驱动已经装好的映匣（wda.prdc.yingxia.dev），逐屏截图 + 断言。
#
#   Scripts/test-duo-ui.sh                          # 真机，全部用例
#   Scripts/test-duo-ui.sh --simulator <UDID>       # 模拟器，同一套用例
#   Scripts/test-duo-ui.sh -only-testing:DuoUITests/DuoAcceptanceUITests/testSettingsShowsVersion
#
# 为什么要另外生成工程：XCUITest 需要一个 test bundle，而主工程没有 UI 测试目标。这里现场生成一个
# 只含「占位宿主 App + UI 测试 bundle」的临时工程，签名沿用 Duo 证书那套（通配 wda.prdc.*），
# 测试代码用 XCUIApplication(bundleIdentifier:) 去驱动真正装好的映匣 —— 所以测的是用户的真实数据。
#
# 产物：build/DuoUI/result.xcresult 与 build/DuoUI/shots/（每屏一张 png）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/DuoUI"
BUNDLE_ID="wda.prdc.yingxia.dev"
CERT_DIR="$HOME/Documents/windows11/编程工具/mac/证书/Duo 证书"
PROFILE="$CERT_DIR/all1023.mobileprovision"
DEVICE=""
SIMULATOR=""
TESTS="$ROOT/UITests/DuoAcceptanceUITests.swift"
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --simulator) SIMULATOR="$2"; shift 2 ;;
        # 换一份测试源码，用来单独验证 runner 通道（见 Docs/真机验收.md）。
        --tests) TESTS="$2"; shift 2 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "挑设备"
if [[ -n "$SIMULATOR" ]]; then
    # 模拟器不需要签名，但 App 必须已经装进去 —— 用例驱动的是已安装的映匣，不是刚构建的产物。
    if ! xcrun simctl get_app_container "$SIMULATOR" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "$SIMULATOR 上没装 $BUNDLE_ID。先用 Scripts/e2e-verify.sh 或 simctl install 装一个 Debug 包。" >&2
        exit 6
    fi
    DEVICE="$SIMULATOR"
    DESTINATION="platform=iOS Simulator,id=$DEVICE"
    SIGNING=(CODE_SIGNING_ALLOWED=NO)
    echo "模拟器 $DEVICE"
else
    if [[ ! -f "$PROFILE" ]]; then echo "找不到描述文件：$PROFILE" >&2; exit 1; fi
    PROFILE_PLIST=$(mktemp)
    trap 'rm -f "$PROFILE_PLIST"' EXIT
    security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
    PROFILE_DEVICES=$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$PROFILE_PLIST" 2>/dev/null \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | tr '\n' ' ')
    if [[ -z "$DEVICE" ]]; then
        CANDIDATES=$(xcrun devicectl list devices 2>/dev/null \
            | awk '/physical/ && (/available \(paired\)/ || /connected/) {print $0}' \
            | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}')
        for candidate in $CANDIDATES; do
            if [[ "$PROFILE_DEVICES" == *"$candidate"* ]]; then DEVICE="$candidate"; break; fi
        done
    fi
    if [[ -z "$DEVICE" ]]; then
        echo "没有插着描述文件授权的那台真机（${PROFILE_DEVICES% }）。" >&2
        exit 3
    fi
    echo "设备 $DEVICE"
    if [[ -n "$PROFILE_DEVICES" && "$PROFILE_DEVICES" != *"$DEVICE"* ]]; then
        echo "⚠️  $DEVICE 不在描述文件里，测试运行器装不上。" >&2
        exit 4
    fi
    DESTINATION="platform=iOS,id=$DEVICE"
    SIGNING=(-allowProvisioningUpdates)
fi

if [[ -z "$SIMULATOR" ]]; then
    if ! xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | grep -q "$BUNDLE_ID"; then
        echo "提示：映匣当前没有在运行，测试会自己拉起它。"
    fi

    # 无线连接能装 App、能手动跑 runner，但 xcodebuild 建不起 XCTestDriver 的 DTX 会话 ——
    # 表现是 runner "exited with code 74 before establishing connection"。插上数据线再跑。
    TRANSPORT=$(xcrun devicectl device info details --device "$DEVICE" --json-output - 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['connectionProperties']['transportType'])" 2>/dev/null || echo unknown)
    echo "连接方式 $TRANSPORT"
    if [[ "$TRANSPORT" != "wired" ]]; then
        echo "" >&2
        echo "⚠️  这台设备不是 USB 连接（${TRANSPORT}）。UI 自动化在无线连接下会被拒绝：" >&2
        echo "    runner 能装上也能自己跑，但 xcodebuild 连不上它，最终报 code 74。" >&2
        echo "    插上数据线（或在 Xcode 的 Devices 窗口确认是 USB）后重跑。" >&2
        echo "" >&2
        if [[ "${DUO_ALLOW_WIRELESS:-0}" != "1" ]]; then exit 5; fi
    fi
fi

step "生成工程"
rm -rf "$OUT"; mkdir -p "$OUT"
# 占位宿主：XCUITest 的 bundle 必须挂在一个 app target 上。它从不被启动，只用来让 xcodebuild 推导
# TEST_HOST / TEST_TARGET_NAME；真正被测的是已安装的映匣。
cat > "$OUT/QAAnchor.swift" <<'SWIFT'
import SwiftUI

@main
struct QAAnchor: App {
    var body: some Scene { WindowGroup { Text("QA Anchor") } }
}
SWIFT
cat > "$OUT/project.yml" <<YAML
name: DuoUI
options:
  deploymentTarget:
    iOS: '17.0'
targets:
  QAAnchor:
    type: application
    platform: iOS
    sources: [QAAnchor.swift]
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: wda.prdc.qaui.host
      CODE_SIGN_STYLE: Manual
      DEVELOPMENT_TEAM: G4XMHC9NWZ
      PROVISIONING_PROFILE_SPECIFIER: all1023
      ENABLE_DEBUG_DYLIB: NO
    info:
      path: AnchorInfo.plist
      properties:
        CFBundleDisplayName: QA Anchor
        UILaunchScreen: {}
  DuoUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [$TESTS]
    dependencies:
      - target: QAAnchor
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: wda.prdc.qaui.tests
      CODE_SIGN_STYLE: Manual
      DEVELOPMENT_TEAM: G4XMHC9NWZ
      PROVISIONING_PROFILE_SPECIFIER: all1023
      GENERATE_INFOPLIST_FILE: YES
      TEST_TARGET_NAME: QAAnchor
schemes:
  DuoAcceptance:
    build:
      targets:
        QAAnchor: all
        DuoUITests: [test]
    test:
      targets: [DuoUITests]
YAML
cd "$OUT"
xcodegen generate --spec project.yml >/dev/null

step "跑用例"
# 测试写完不删：失败时 result.xcresult 里留着日志和截图。
set +e
xcodebuild -project DuoUI.xcodeproj -scheme DuoAcceptance \
    -destination "$DESTINATION" \
    -derivedDataPath "$OUT/DerivedData" \
    -resultBundlePath "$OUT/result.xcresult" \
    "${SIGNING[@]}" \
    -collect-test-diagnostics never \
    test "${EXTRA[@]+"${EXTRA[@]}"}" 2>&1 | tee "$OUT/test.log" | grep -E "Test Suite|Test Case|error:|warning: .*(sign|provision)|XCTAssert|TEST (SUCCEEDED|FAILED)" || true
STATUS=${PIPESTATUS[0]}
set -e

step "导出截图"
mkdir -p "$OUT/shots"
if [[ -d "$OUT/result.xcresult" ]]; then
    xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/shots" >/dev/null 2>&1 || true
    # 附件导出来后是随机 UUID 文件名；按附件名改回 <屏名>.png。
    # 名字长这样：settings_0_CB149FA5-DEF7-405F-982F-CE64EE4656E0.png —— 中间那段是 xcresult
    # 自己加的序号和 UUID，去掉后剩下的才是用例里给的名字。
    python3 - "$OUT/shots" <<'PY'
import json, os, re, sys
root = sys.argv[1]
manifest = os.path.join(root, "manifest.json")
if os.path.exists(manifest):
    for entry in json.load(open(manifest)):
        for attachment in entry.get("attachments", []):
            name = (attachment.get("suggestedHumanReadableName") or "").strip()
            src = os.path.join(root, attachment.get("exportedFileName", ""))
            if not name or not os.path.exists(src):
                continue
            stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", re.sub(r"\.png$", "", name, flags=re.I))
            os.replace(src, os.path.join(root, stem.replace("/", "-") + ".png"))
PY
    COUNT=$(ls "$OUT/shots"/*.png 2>/dev/null | wc -l | tr -d ' ')
    echo "截图 $COUNT 张 → $OUT/shots"
    ls "$OUT/shots"/*.png 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
fi

if [[ $STATUS -ne 0 ]]; then
    echo "" >&2
    echo "用例失败（退出码 $STATUS）。日志：$OUT/test.log" >&2
    grep -E "error:|failed|XCTAssert" "$OUT/test.log" | head -20 >&2 || true
fi
exit $STATUS
