#!/bin/bash
# 上游原版 vs 映匣：同一模拟器、同一订阅、同一 QA 参数，逐屏截图，两两比对。
#
#   Scripts/qa-fixture/ab-compare.sh <DEV_UDID> <上游.app> <映匣.app>
#
# 产物：build/ab/<时间戳>/{upstream,ours}/<屏名>.png + report.txt
# 判据：同名两图的 md5 —— 相同=这屏没被改；不同=被改过（需要人看是不是改坏了）
set -uo pipefail
DEV="${1:?UDID}"; UP="${2:?上游 .app}"; OUR="${3:?映匣 .app}"
BID="wda.prdc.yingxia.dev"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="build/ab/$STAMP"
mkdir -p "$OUT/upstream" "$OUT/ours"

# 同一份订阅，两版都用它，避免数据差异
SUB="${QA_SUB:-https://raw.githubusercontent.com/qist/tvbox/master/fty.json}"

# name:settle —— sleep 时长照抄 Scripts/e2e-verify.sh（兄弟会话验证过）：
# 首屏等订阅合并 5s，源与设置等列表首帧 4s，其余 3s。
# 不加 -qaIsolatedData：e2e-verify.sh 也没加，加了反而让首屏等不到订阅。
SHOTS=(
  "home:5" "discover:3" "live:3" "music:3" "search:3" "sites:4"
  "files:3" "favorites:3" "history:3" "downloads:3" "settings:4"
)

shoot () {
  local app="$1" dir="$2"
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
  xcrun simctl uninstall "$DEV" "$BID" 2>/dev/null || true
  xcrun simctl install "$DEV" "$app" >/dev/null 2>&1 || { echo "  安装失败: $app"; return 1; }
  for entry in "${SHOTS[@]}"; do
    local name="${entry%%:*}" settle="${entry##*:}"
    # 不传 -qaSubscription：每次启动都去拉远程订阅会卡在加载态，
    # 首屏和别的屏全变成同一张 loading 图（实测 11 屏只剩 2 种画面）。
    # e2e-verify.sh 也不传，用的是 App 自己的默认订阅。
    xcrun simctl launch "$DEV" "$BID" -qaSection "$name" >/dev/null 2>&1
    sleep "$settle"
    # 用 hinge 截图：Duo 有两个 framebuffer，simctl io 会抓到没在显示 UI 的那块（黑屏）。
    # hinge screenshot 抓「承载 UI 的那块」。
    if [ -x "Scripts/hinge/scripts/hinge" ]; then
      Scripts/hinge/scripts/hinge -d "$DEV" screenshot "$dir/$name.png" >/dev/null 2>&1
    else
      xcrun simctl io "$DEV" screenshot "$dir/$name.png" >/dev/null 2>&1
    fi
    printf "    %s\n" "$name"
  done
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
}

# 冷启动一次模拟器，整轮只做这一回。
# SpringBoard 上「在"映匣"中打开?」确认框属于系统，terminate/launch 都清不掉，
# 它会糊在之后每一张截图上。e2e-verify.sh 的做法是先 shutdown+boot 一次，
# 然后一直用同一台已启动的模拟器（不是每版都重启 —— 每版重启反而会让前几屏来不及渲染）。
echo "▸ 冷启动模拟器"
xcrun simctl shutdown "$DEV" >/dev/null 2>&1 || true
xcrun simctl boot "$DEV" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1 || true

echo "▸ 上游原版"
shoot "$UP" "$OUT/upstream"
echo "▸ 映匣"
shoot "$OUR" "$OUT/ours"

echo "▸ 比对"
REPORT="$OUT/report.txt"
: > "$REPORT"
for entry in "${SHOTS[@]}"; do
  name="${entry%%:*}"
  a="$OUT/upstream/$name.png"; b="$OUT/ours/$name.png"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    printf "  %-12s 缺图\n" "$name" | tee -a "$REPORT"; continue
  fi
  ma=$(md5 -q "$a"); mb=$(md5 -q "$b")
  if [ "$ma" = "$mb" ]; then
    printf "  %-12s 相同\n" "$name" | tee -a "$REPORT"
  else
    printf "  %-12s 不同  ↑上游 %s ↓映匣 %s\n" "$name" "$a" "$b" | tee -a "$REPORT"
  fi
done
echo
echo "产物: $OUT"
