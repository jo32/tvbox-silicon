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

SHOTS=(
  "home|-qaSection home"
  "discover|-qaSection discover"
  "live|-qaSection live"
  "music|-qaSection music"
  "search|-qaSection search"
  "sites|-qaSection sites"
  "files|-qaSection files"
  "favorites|-qaSection favorites"
  "history|-qaSection history"
  "downloads|-qaSection downloads"
  "settings|-qaSection settings"
)

shoot () {
  local app="$1" dir="$2"
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
  xcrun simctl uninstall "$DEV" "$BID" 2>/dev/null || true
  xcrun simctl install "$DEV" "$app" >/dev/null 2>&1 || { echo "  安装失败: $app"; return 1; }
  for entry in "${SHOTS[@]}"; do
    local name="${entry%%|*}" args="${entry#*|}"
    # shellcheck disable=SC2086
    xcrun simctl launch "$DEV" "$BID" $args -qaSubscription "$SUB" -qaIsolatedData 1 -qaKeepAwake 1 >/dev/null 2>&1
    sleep 6
    xcrun simctl io "$DEV" screenshot "$dir/$name.png" >/dev/null 2>&1
    printf "    %s\n" "$name"
  done
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
}

echo "▸ 上游原版"
shoot "$UP" "$OUT/upstream"
echo "▸ 映匣"
shoot "$OUR" "$OUT/ours"

echo "▸ 比对"
REPORT="$OUT/report.txt"
: > "$REPORT"
for entry in "${SHOTS[@]}"; do
  name="${entry%%|*}"
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
