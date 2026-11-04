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
# 冷启动一次模拟器。
#
# SpringBoard 上的「在“映匣”中打开?」确认框属于系统，不属于 App：它由早前的 `openurl` 留下，
# `simctl terminate` 和重新 `launch` 都不会把它清掉，于是它糊在之后每一张截图上，而自检只看到
# 「文件够大」就放行。重启模拟器是唯一不用点屏幕就能清掉它的办法。
xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

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
shot() { xcrun simctl io "$DEVICE" screenshot "$RUN/$1.png" >/dev/null 2>&1; }

# 5. 每个 section 截图。
#
#    这里**不用深链**：iOS 26 上 `simctl openurl yingxia://…` 会先弹一个「在“映匣”中打开?」系统确认框，
#    每张图都是那个弹窗，自检却因为「文件够大」而全部通过 —— 一整套截图什么都没验证到。
#    改用 App 自带的调试启动参数（见 App/QALaunch.swift）：`-qaSection <key>` 直接落在那一屏，
#    没有弹窗，也不留下持久状态（启动参数只进 UserDefaults 的 argument 域）。
launch_section() {
    local key="$1" settle="${2:-3}" tag="$3"
    xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -qaSection "$key" >/dev/null
    # 页要真的渲染出来才截：首屏等订阅合并，其余等列表首帧。
    sleep "$settle"
    shot "$tag"
    echo "$tag  ← section $key"
}

for entry in "home:Watch Now:5" "discover:Discover:3" "live:Live TV:3" "music:Music:3" \
             "search:Global Search:3" "sites:Sources:4" "files:Cloud Files:3" "favorites:Favorites:3" \
             "history:Playback History:3" "downloads:Downloads:3" "settings:Settings:4"; do
    # key:name:settle —— 首屏要等订阅合并完才有内容，源与设置要等列表首帧。
    IFS=: read -r key name settle <<< "$entry"
    launch_section "$key" "$settle" "section-$key"
done

# 6. 自检。两个判据，缺一不可：
#    a) 图不能太小（黑屏 / 启动画面）；
#    b) **任意两屏的指纹不能相同** —— 首屏之外每屏都该和别的屏有区别。这一条正是为了抓住
#       「每张图都是同一个系统弹窗」那类假通过：尺寸够大、指纹全同。
step "自检"
FAILED=0
# macOS 自带的是 bash 3.2，没有关联数组，所以用两个平行数组记指纹。
SEEN_HASHES=()
SEEN_NAMES=()
for png in "$RUN"/*.png; do
    size=$(stat -f%z "$png" 2>/dev/null || echo 0)
    if [[ "$size" -lt 10240 ]]; then
        echo "⚠️  截图过小（可能黑屏）：$png（$size 字节）"
        FAILED=1
        continue
    fi
    # 缩到 64pt 宽再取指纹：状态栏时钟每次都不同，整图 md5 会永远不等，缩小后不影响页面差异。
    thumb="${png%.png}.thumb"
    sips -Z 64 "$png" --out "$thumb" >/dev/null 2>&1 || cp "$png" "$thumb"
    fingerprint=$(md5 -q "$thumb")
    rm -f "$thumb"
    twin=""
    for i in ${!SEEN_HASHES[@]+"${!SEEN_HASHES[@]}"}; do
        [[ "${SEEN_HASHES[$i]}" == "$fingerprint" ]] && twin="${SEEN_NAMES[$i]}"
    done
    if [[ -n "$twin" ]]; then
        echo "⚠️  $png 与 $twin 画面相同（很可能没进到目标页）"
        FAILED=1
    else
        SEEN_HASHES+=("$fingerprint")
        SEEN_NAMES+=("$png")
    fi
done
[[ $FAILED -eq 0 ]] && echo "✅ 全部截图非空且互不相同，端到端验证通过。产物在 $RUN/"
exit $FAILED
