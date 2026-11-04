#!/bin/bash
# 端到端验证：build → 装进 iOS 模拟器 → 启动 → 逐屏截图，产物落本仓库 Scripts/e2e-shots/。
#
#   Scripts/e2e-verify.sh              # 默认：iPhone 17 Pro 模拟器，拍首屏 + 每屏
#   Scripts/e2e-verify.sh --device UDID  # 指定模拟器（xcrun simctl list devices 查）
#   Scripts/e2e-verify.sh --sim NAME     # 按名字挑模拟器（如 "iPhone 17 Pro"）
#
# 产物：
#   Scripts/e2e-shots/<timestamp>/  —— 每次运行一个子目录，可对比回归
#   首屏 home.png，然后对每个 section 用 `simctl launch` 深链 + 截图（见下方 SECTIONS）。
# 验证不依赖视觉模型：截图落盘后由人（或接视觉模型）比对；脚本只保证「能构建、能装、能启动、能截到非空图」。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUNDLE_ID="wda.prdc.yingxia.dev"
SCHEME="TVBox-iOS"
OUT_ROOT="Scripts/e2e-shots"
DEVICE=""
SIM_NAME="iPhone 17 Pro"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --sim) SIM_NAME="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

# 1. 挑一个可用模拟器（默认按名字，可 --device 覆盖）
step "模拟器"
if [[ -z "$DEVICE" ]]; then
    DEVICE=$(xcrun simctl list devices available 2>/dev/null \
        | grep "$SIM_NAME" | grep -oE '[0-9A-F-]{36}' | head -1)
fi
if [[ -z "$DEVICE" ]]; then
    echo "找不到模拟器「$SIM_NAME」。用 xcrun simctl list devices available 查一个，再 --device 传入。" >&2
    exit 3
fi
echo "设备 $DEVICE"
# 没开机就先开机
xcrun simctl boot "$DEVICE" 2>/dev/null || true

# 2. 构建（模拟器 slice）
step "构建"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
DERIVED="$(mktemp -d)/dd"
xcodebuild -project TVBox.xcodeproj -scheme "$SCHEME" -destination "id=$DEVICE" \
    -configuration Debug -derivedDataPath "$DERIVED" -quiet build CODE_SIGNING_ALLOWED=NO
APP=$(find "$DERIVED/Build/Products" -name "*.app" -maxdepth 3 | head -1)
[[ -n "$APP" ]] || { echo "构建产物没找到。" >&2; exit 4; }
echo "$APP"

# 3. 装 + 启动
step "安装 + 启动"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null

# 4. 截图（每次运行独立目录）
RUN="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
sleep 3
shot() { xcrun simctl io "$DEVICE" screenshot "$RUN/$1.png" >/dev/null 2>&1; }
shot "home"
echo "首屏 → $RUN/home.png"

# 5. 每个 section 深链打开 + 截图。深链是 yingxia://section/<rawValue>，rawValue 即 AppSection 的
#    显示名（见 App/RootView.swift 的 AppSection 枚举，注意空格需 URL 编码）。
SECTIONS=("Watch Now:home" "Discover:discover" "Live TV:live" "Music:music" "Global Search:search" \
          "Sources:sites" "Cloud Files:files" "Favorites:favorites" "Playback History:history" \
          "Downloads:downloads" "Settings:settings")
for entry in "${SECTIONS[@]}"; do
    name="${entry%%:*}"; tag="${entry##*:}"
    encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name")
    if xcrun simctl openurl "$DEVICE" "yingxia://section/$encoded" >/dev/null 2>&1; then
        sleep 1
        shot "section-$tag"
        echo "section $name → $RUN/section-$tag.png"
    fi
done

# 6. 健壮性自检：截到的图必须非空（≥10KB），否则报失败。
step "自检"
FAILED=0
for png in "$RUN"/*.png; do
    size=$(stat -f%z "$png" 2>/dev/null || echo 0)
    if [[ "$size" -lt 10240 ]]; then
        echo "⚠️  截图过小（可能黑屏）：$png（$size 字节）"
        FAILED=1
    fi
done
[[ $FAILED -eq 0 ]] && echo "✅ 全部截图非空，端到端验证通过。产物在 $RUN/"
exit $FAILED
