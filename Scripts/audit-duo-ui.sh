#!/bin/bash
# Duo 折叠屏三形态全页面 UI 审计：用深链遍历 13 个 section + 30 个 page，
# 对三种折叠形态 × 浅色/深色两套主题逐屏截图，回传到本仓库供视觉审计。
#
#   Scripts/audit-duo-ui.sh                          # 全量：三形态 × 双主题 × 全页面
#   Scripts/audit-duo-ui.sh --morph cover            # 只拍折叠外屏
#   Scripts/audit-duo-ui.sh --theme light            # 只拍浅色
#   Scripts/audit-duo-ui.sh --page settings          # 只拍 settings 深链页
#
# 三种折叠形态（同一台 Duo 用 hinge 切角度 + 方向）：
#   cover   折叠外屏   close                 2034×1398 横屏（cover 屏）
#   land    展开横屏   open + landscape-left  2007×2853（双屏大屏）
#   port    展开竖屏   open + portrait        2853×2007（双屏竖屏）
#
# 依赖订阅的页面（site:/detail:/channels: 等）通过本地 fixture 注入确定性数据：
#   Scripts/qa-fixture/server.py  订阅 http://127.0.0.1:8899/sub.json
#
# 产物：Scripts/e2e-shots/duo-audit/<timestamp>/<morph>-<theme>-<page>.png + manifest.json
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUNDLE_ID="wda.prdc.yingxia.dev"
OUT_ROOT="Scripts/e2e-shots/duo-audit"
HINGE="Scripts/hinge/scripts/hinge"
FIXTURE_PORT=8899
SUB="http://127.0.0.1:8899/sub.json"
DEV="364A1BDF-E7A7-483A-9273-8384573CD250"   # DuoTest

# 三形态 → hinge 切法
set_morph() {
  case "$1" in
    cover) "$HINGE" -d "$DEV" close >/dev/null 2>&1 ;;
    land)  "$HINGE" -d "$DEV" open >/dev/null 2>&1; sleep 1; "$HINGE" -d "$DEV" orient landscape-left >/dev/null 2>&1 ;;
    port)  "$HINGE" -d "$DEV" open >/dev/null 2>&1; sleep 1; "$HINGE" -d "$DEV" orient portrait >/dev/null 2>&1 ;;
  esac
  sleep 2
}

ONLY_MORPH=""; ONLY_THEME=""; ONLY_PAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --morph) ONLY_MORPH="$2"; shift 2 ;;
    --theme) ONLY_THEME="$2"; shift 2 ;;
    --page) ONLY_PAGE="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

# ---- 页面清单：name -> 启动参数（settle 秒）----
# 第一列文件名 tag，第二列 -qaSection/-qaPage 参数，第三列等待渲染秒数。
PAGES=(
  # 13 个根 section
  "home:-qaSection home:5"
  "discover:-qaSection discover:3"
  "live:-qaSection live:3"
  "music:-qaSection music:3"
  "search:-qaSection search:3"
  "sites:-qaSection sites:4"
  "files:-qaSection files:3"
  "favorites:-qaSection favorites:3"
  "history:-qaSection history:3"
  "downloads:-qaSection downloads:3"
  "settings:-qaSection settings:4"
  "more:-qaSection more:3"
  # 30 个深链 page
  "player:-qaSection settings -qaPage player:4"
  "player-error:-qaSection settings -qaPage player-error:4"
  "player-stall:-qaSection settings -qaPage player-stall:4"
  "vault:-qaSection settings -qaPage vault:3"
  "playback-settings:-qaSection settings -qaPage playback:3"
  "privacy-settings:-qaSection settings -qaPage privacy:3"
  "resource-order:-qaSection settings -qaPage resource-order:3"
  "segment-sources:-qaSection settings -qaPage segment-sources:3"
  "speech-subtitles:-qaSection settings -qaPage speech-subtitles:3"
  "cache:-qaSection settings -qaPage cache:3"
  "licenses:-qaSection settings -qaPage licenses:3"
  "feedback:-qaSection settings -qaPage feedback:3"
  "runtime:-qaSection settings -qaPage runtime:3"
  "logs:-qaSection settings -qaPage logs:3"
  "cloud-accounts:-qaSection files -qaPage cloud-accounts:3"
  "cloud-login-quark:-qaSection files -qaPage cloud-login:quark:3"
  "cloud-login-uc:-qaSection files -qaPage cloud-login:uc:3"
  "cloud-login-baidu:-qaSection files -qaPage cloud-login:baidu:3"
  "cloud-login-aliyun:-qaSection files -qaPage cloud-login:aliyun:3"
  "bilibili-account:-qaSection settings -qaPage bilibili-account:3"
  "douyin-account:-qaSection settings -qaPage douyin-account:3"
  "bilibili-live:-qaSection live -qaPage live:bilibili:3"
  "douyu-live:-qaSection live -qaPage live:douyu:3"
  "huya-live:-qaSection live -qaPage live:huya:3"
  "douyin-live:-qaSection live -qaPage live:douyin:3"
  "danmaku-list:-qaSection settings -qaPage danmaku-list:4"
  "web-sign-in-bilibili:-qaSection settings -qaPage web-sign-in:bilibili:3"
  "web-sign-in-quark:-qaSection settings -qaPage web-sign-in:quark:3"
  "web-sign-in-uc:-qaSection settings -qaPage web-sign-in:uc:3"
  "web-sign-in-baidu:-qaSection settings -qaPage web-sign-in:baidu:3"
  "web-sign-in-aliyun:-qaSection settings -qaPage web-sign-in:aliyun:3"
  "plugin-sign-in-baidu:-qaSection settings -qaPage plugin-sign-in:baidu:3"
  "plugin-sign-in-aliyun:-qaSection settings -qaPage plugin-sign-in:aliyun:3"
  # 依赖订阅的页（sub）
  "detail:-qaSection sites -qaPage detail:qa:1:5"
  "site-home:-qaSection sites -qaPage site:qa:5"
  "channels:-qaSection live -qaPage channels:0:5"
)

needs_sub() { case "$1" in detail|site-home|channels) return 0 ;; *) return 1 ;; esac; }

# ---- 1. 起 fixture 服务（若未起）----
step "fixture 服务"
FIXTURE_PID=""
if ! curl -s -o /dev/null "http://127.0.0.1:$FIXTURE_PORT/sub.json"; then
  echo "  起本地 fixture 服务（127.0.0.1:$FIXTURE_PORT）"
  python3 Scripts/qa-fixture/server.py >/tmp/qa-fixture.log 2>&1 &
  FIXTURE_PID=$!
  trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$FIXTURE_PORT/sub.json" && break; sleep 0.3; done
else
  echo "  fixture 服务已在运行"
fi

# ---- 2. 逐形态逐主题逐页截图 ----
RUN="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"

MANIFEST=()

alive() { python3 -c "
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('L')
e = im.getextrema()
print('ok' if e[1] > 12 else 'dark')
" "$1"; }

snap() { "$HINGE" -d "$DEV" screenshot "$1" >/dev/null 2>&1; }

for morph in cover land port; do
  [[ -n "$ONLY_MORPH" && "$ONLY_MORPH" != "$morph" ]] && continue
  set_morph "$morph"
  echo "  形态 $morph 就绪"

  for theme in light dark; do
    [[ -n "$ONLY_THEME" && "$ONLY_THEME" != "$theme" ]] && continue
    for entry in "${PAGES[@]}"; do
      tag="${entry%%:*}"; rest="${entry#*:}"
      args="${rest%:*}"
      settle="${entry##*:}"
      [[ -n "$ONLY_PAGE" && "$ONLY_PAGE" != "$tag" ]] && continue

      local_args="$args"
      if needs_sub "$tag"; then local_args="$local_args -qaSubscription $SUB"; fi
      local_args="$local_args -qaKeepAwake 1"
      if [[ "$theme" == "dark" ]]; then local_args="$local_args -AppleInterfaceStyle Dark"
      else local_args="$local_args -AppleInterfaceStyle Light"; fi

      xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
      # shellcheck disable=SC2086
      xcrun simctl launch "$DEV" "$BUNDLE_ID" $local_args >/dev/null 2>&1
      sleep "$settle"

      fname="$morph-$theme-$tag.png"
      snap "$RUN/$fname"
      if [[ "$(alive "$RUN/$fname" 2>/dev/null)" != "ok" ]]; then
        echo "  ⚠ $fname 黑屏，删除"
        rm -f "$RUN/$fname"
      else
        MANIFEST+=("$fname")
        echo "  $fname"
      fi
    done
  done
done

# ---- 3. 写 manifest ----
python3 - "$RUN" "${MANIFEST[@]}" <<'PY'
import json, sys
run, *files = sys.argv[1:]
json.dump({"run": run.split("/")[-1], "count": len(files), "files": files}, open(f"{run}/manifest.json", "w"), ensure_ascii=False, indent=2)
print(f"\n完成：{len(files)} 张 → {run}")
PY
