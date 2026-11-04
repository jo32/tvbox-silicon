# 已设计、但还差一条数据通路的两个页面

这两个视图的界面与文案是完整的，缺的是它们背后的真东西。放进 `App/` 会让设置页出现一个
看起来能按、按了什么也不会发生的开关，所以先存放在这里，等数据通路补上再搬回 `App/` 并挂入口。

`App/` 是 Xcode 目标唯一的源码目录，因此这里的文件不参与编译。

## ArtworkLanguageView.swift —— 海报 / 标志的图片语言

页面可用的前提是能按语言挑图。现在 `TMDBMatch` 只请求详情（`language=` 影响标题、简介等**文字**），
`Details.poster` 是详情接口顺带给的那一张，没有 `/movie/{id}/images?include_image_language=` 这条通路，
模型里也没有 `original_language`。要接线需要：

1. `TMDBMatch.Details` 增加 `originalLanguage: String?`（TMDB 详情本身返回 `original_language`）。
2. 详情请求带上 `append_to_response=images&include_image_language=<code>,null`，解析 `images.posters[]`
   的 `iso_639_1` / `file_path`。
3. `ArtworkLanguage` 决定选哪一张：`metadata` 用现成的，`original` 用 `original_language`，
   `fixed(code)` 用指定语言，都没有就回落到现成的。
4. 回落要能被看见：先出旧图、新图到了再替换——这正是页面文案里写的“多一次请求”。

选项 `.metadata` 不产生额外请求，其余三个会，这一点 `ArtworkLanguage.costsExtraRequests` 已经算好了。

## EnvironmentsView.swift —— 观看环境（数据分区）

页面可用的前提是记录真的带环境标记、读取时真的按它过滤。现在 `PlaybackHistory`、
`Favorites`、`pinnedSources`、订阅都只有一份，没有 `environmentID`。要接线需要：

1. `PlaybackHistoryEntry` 加 `environment: UUID?`（`nil` = 升级前的老记录，归默认环境），
   并且 **`id` 要带上环境**：同一个片名在两个环境里各有一份进度，只靠
   `PlaybackHistoryContext.id`（origin|source|video）会互相覆盖。
2. 写入时盖当前环境的章，读取时按 `environments.activeID` 过滤；`Store.visibleHistory`
   是唯一的读入口，改在那里就够。
3. 同上处理收藏、置顶源、订阅——页面 footer 承诺的就是这些。
4. 云端同步（`CloudSync.register("history", …)`）要把环境一起带上，否则两台机器的分区会对不上。

只要有一条没做到，页面上的“删除环境只删它自己的数据”就是假话，所以先不挂入口。
