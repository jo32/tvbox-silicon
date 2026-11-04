# 本地订阅夹具

用一条自己生成的订阅，把「导入订阅 → 列表 → 详情 → 播放」整条链路跑通，
不依赖公网、不依赖别人的源，可重复回归。

## 为什么需要

`Scripts/e2e-verify.sh` 只验证「每个页面能打开、截图互不相同」。
它不能证明源能被解析、详情能拉到、视频能播 —— 那三件事才是播放器的核心。
这里补上这一段。

## 用法

```bash
# 1) 起服务（默认 127.0.0.1:8899）
python3 Scripts/qa-fixture/server.py &

# 2) 装到模拟器
DEV=$(xcrun simctl list devices booted -j | python3 -c "import json,sys;print(list(json.load(sys.stdin)['devices'].values())[0][0]['udid'])")
xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -destination "id=$DEV" \
  -derivedDataPath /tmp/qa-dd build
xcrun simctl install "$DEV" /tmp/qa-dd/Build/Products/Debug-iphonesimulator/TVBox-iOS.app

# 3) 导入并播放（关键：用 -qaPage play-source:，不要用 -qaPlay）
xcrun simctl terminate "$DEV" wda.prdc.yingxia.dev 2>/dev/null
xcrun simctl launch "$DEV" wda.prdc.yingxia.dev \
  -qaSubscription "http://127.0.0.1:8899/sub.json" \
  -qaPage "play-source:qa"

# 4) 看结果
DATA=$(xcrun simctl get_app_container "$DEV" wda.prdc.yingxia.dev data)
cat "$DATA/Library/Caches/qa-playback.json"
```

期望输出里有 `"ready":true` 和 `"duration":3`。

## 三个踩过的坑（都写进代码注释了）

**① `-qaPlay` 有竞态，要用 `-qaPage play-source:`**

`-qaPlay` 读 `store.subscription` 时，`-qaSubscription` 的导入还在异步进行，
于是拿到 nil，静默什么都不做。`play-source:` 分支自己重新读一次，没有这个问题。

**② 服务器必须支持 Range**

第一版用 `BaseHTTPRequestHandler` 直接回 200 + 全量 body，AVPlayer 报
`-12939 byte range length mismatch`。必须实现 `bytes=S-E` → 206 + `Content-Range`。

**③ api 路由要看查询串，不能只看路径**

`p == "/api"` 匹配不到 `"/api?ac=detail"`。写成 `p.rstrip("/") == "/api"` 再拆查询串。

## 文件

- `server.py` —— 订阅 + 原生 API + 静态文件（支持 Range）
- `clip.mp4` —— 3 秒 H.264+AAC 测试片（640x360）
- `poster.jpg` —— 海报

## 逐源矩阵：区分「源不行」和「我们解析坏了」

```bash
Scripts/qa-fixture/matrix.sh <DEV_UDID> 玩偶 MTV1 seed YGP
```

判据只看 `qa-playback.json`：**文件不存在 = 通过**（`ready=true` 时代码根本不写这个文件）。

实测（2026-11-04，模拟器，真实源）：

| 源 | 结果 |
|---|---|
| `MTV1` 易听音乐 | 通过 |
| `YGP` 荐影预告片 | 通过 |
| `玩偶` 4K弹幕 | `resolve: No videos` |
| `seed` 聚剧四盘 | `resolve: 插件没有返回内容` |

**结论：解析链路是好的，`玩偶`/`seed` 是源自身的问题**（首页和分类都返回空）。
这条矩阵的价值就在这里 —— 单个源失败时能立刻分辨是代码坏了还是源挂了。

## 字幕这一段的结论（重要）

type 3/4 源在 `Catalog.preparePlayback` 里解析 `result["subs"]`（见 `ExternalSubtitle.parse`），
但 **type 1（原生 API）的直连分支根本不传 `subtitles`** —— 上游 `Catalog.swift:468`
也是同一个写法。所以：

- 想在字幕自绘层上做验证，fixture 必须是 **type 3**，并用 `play=` 返回 `subs`
- type 1 源没有外挂字幕，这是上游本来的限制，不是我们的回归
