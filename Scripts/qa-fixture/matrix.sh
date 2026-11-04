#!/bin/bash
# 逐源跑「播放」链路，记录每条源的结果。用于区分「源本身不行」和「我们解析坏了」。
#
#   Scripts/qa-fixture/matrix.sh <DEV_UDID> <源key> [<源key> ...]
#
# 每条的结论读 $DATA/Library/Caches/qa-playback.json：
#   文件不存在      → 走通了（ready=true 时代码不写此文件）
#   stage=resolve   → 解析阶段失败，error 是原因
set -uo pipefail
DEV="${1:?需要设备 UDID}"; shift
BID="wda.prdc.yingxia.dev"
DATA=$(xcrun simctl get_app_container "$DEV" "$BID" data 2>/dev/null)
[ -z "$DATA" ] && { echo "找不到 app 容器"; exit 1; }

for key in "$@"; do
  rm -f "$DATA/Library/Caches/qa-playback.json"
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
  sleep 2
  xcrun simctl launch "$DEV" "$BID" -qaPage "play-source:$key" >/dev/null 2>&1
  sleep 22
  printf '  %-10s → ' "$key"
  if [ -f "$DATA/Library/Caches/qa-playback.json" ]; then
    python3 -c "
import json
d=json.load(open('$DATA/Library/Caches/qa-playback.json'))
print(f\"{d.get('stage')}: {d.get('error')}\")"
  else
    echo "通过（无失败记录）"
  fi
done
