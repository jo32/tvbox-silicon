#!/bin/bash
# 真机逐屏截图 —— 不需要数据线，也不需要 UI 自动化。
#
#   Scripts/shoot-duo.sh                 # 默认设备，全部屏
#   Scripts/shoot-duo.sh --device <UDID>
#   Scripts/shoot-duo.sh --out <目录>
#
# 和 Scripts/test-duo-ui.sh 的分工：那个能点、能断言，但要 USB；这个只会「带参数启动 + 截图」，
# 无线也行，代价是拍不到需要点击才能到的地方。屏幕息屏时截出来是全黑 —— 脚本会检测并直接说清楚，
# 而不是留下一堆黑图让人以为 App 崩了。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="wda.prdc.yingxia.dev"
PROFILE="$HOME/Documents/windows11/编程工具/mac/证书/Duo 证书/all1023.mobileprovision"
DEVICE=""
OUT="$ROOT/build/DuoUI/live/$(date +%Y%m%d-%H%M%S)"
SETTLE=4

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

if [[ -z "$DEVICE" ]]; then
    # 解出来的 plist 先落盘：PlistBuddy 读 /dev/stdin 会挂住。
    PROFILE_PLIST=$(mktemp)
    trap 'rm -f "$PROFILE_PLIST"' EXIT
    security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null || true
    PROFILE_DEVICES=$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$PROFILE_PLIST" 2>/dev/null \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | tr '\n' ' ')
    CANDIDATES=$(xcrun devicectl list devices 2>/dev/null \
        | awk '/physical/ && (/available \(paired\)/ || /connected/) {print $0}' \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}')
    for candidate in $CANDIDATES; do
        if [[ -z "$PROFILE_DEVICES" || "$PROFILE_DEVICES" == *"$candidate"* ]]; then DEVICE="$candidate"; break; fi
    done
fi
[[ -n "$DEVICE" ]] || { echo "没有可用的真机。" >&2; exit 3; }
echo "设备 $DEVICE"

mkdir -p "$OUT"
light() { python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
print("awake" if max(im.getextrema(), key=lambda e: e[1])[1] > 8 else "dark")
PY
}

# 先确认屏幕是亮的：息屏时 xcrun 照样能截，截出来全黑，看起来像 App 白屏/崩溃的假象。
xcrun devicectl device capture screenshot --device "$DEVICE" --destination "$OUT/_probe.png" >/dev/null 2>&1 || true
if [[ "$(light "$OUT/_probe.png")" == "dark" ]]; then
    rm -f "$OUT/_probe.png"
    echo "" >&2
    echo "⚠️  屏幕是黑的。devicectl 能截息屏，但截出来是全黑 —— 先点亮手机再跑。" >&2
    echo "    （App 的 -qaKeepAwake 只在运行期间阻止自动锁屏，唤不醒已经黑掉的屏。）" >&2
    exit 4
fi
rm -f "$OUT/_probe.png"

# 屏名:启动参数。和 UITests/DuoAcceptanceUITests.swift 保持同一批，方便两边对照。
SCREENS=(
    "home:-qaSection home"
    "discover:-qaSection discover"
    "live:-qaSection live"
    "sites:-qaSection sites"
    "favorites:-qaSection favorites"
    "downloads:-qaSection downloads"
    "settings:-qaSection settings"
    "more:-qaSection more"
    "vault:-qaSection settings -qaPage vault"
)

step "逐屏截图"
for entry in "${SCREENS[@]}"; do
    name="${entry%%:*}"
    args="${entry#*:}"
    # shellcheck disable=SC2086
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" \
        -- $args -qaKeepAwake 1 >/dev/null 2>&1 || true
    sleep "$SETTLE"
    xcrun devicectl device capture screenshot --device "$DEVICE" --destination "$OUT/$name.png" >/dev/null 2>&1 || true
    if [[ "$(light "$OUT/$name.png")" == "dark" ]]; then
        echo "  $name：黑屏（拍照时息屏了，或 App 没起来）" >&2
        rm -f "$OUT/$name.png"
    else
        echo "  $name"
    fi
done

COUNT=$(ls -1 "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
step "完成"
echo "截图 $COUNT 张 → $OUT"
if [[ $COUNT -lt ${#SCREENS[@]} ]]; then
    echo "有屏没拍到（息屏或启动失败）。点亮手机、关掉自动锁屏后重跑。" >&2
    exit 5
fi
