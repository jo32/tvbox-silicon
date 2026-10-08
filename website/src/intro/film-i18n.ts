// Film copy is written in English in film.html; these tables swap each text node, chapter
// name and label for the page language. Terms follow the site copy in i18n/strings.ts.
import type { Lang } from "../i18n/strings";

type Row = [ja: string, ko: string, zhHant: string];

const T: Record<string, Row> = {
  // Boot and outro
  "All your sources. One big screen.": ["すべてのソースを、ひとつの大画面で。", "모든 소스를, 하나의 큰 화면에서.", "所有片源，盡在大螢幕。"],
  "A native TVBox player for Apple TV": ["Apple TV のためのネイティブ TVBox プレーヤー", "Apple TV를 위한 네이티브 TVBox 플레이어", "為 Apple TV 打造的原生 TVBox 播放器"],
  "Coming soon": ["近日公開", "출시 예정", "即將推出"],
  "Yingxia doesn’t host or provide any content. It plays the subscriptions you add.": ["映匣はコンテンツをホスト・提供しません。追加した配信設定を再生するだけです。", "Yingxia는 어떤 콘텐츠도 호스팅하거나 제공하지 않습니다. 추가한 구독을 재생할 뿐입니다.", "映匣不託管也不提供任何內容，只播放你加入的訂閱。"],

  // Subscriptions
  "Subscriptions": ["配信設定", "구독", "訂閱"],
  "Built for Android TV boxes": ["Android TV ボックス向け", "Android TV 박스용", "為 Android 電視盒設計"],
  "JSON APIs": ["JSON API", "JSON API", "JSON API"],
  "JavaScript plugins": ["JavaScript プラグイン", "JavaScript 플러그인", "JavaScript 外掛"],
  "JAR spiders": ["JAR スパイダー", "JAR 스파이더", "JAR 爬蟲"],
  "M3U & TXT playlists": ["M3U・TXT プレイリスト", "M3U·TXT 재생 목록", "M3U、TXT 播放清單"],
  "Apple TV can’t run Android plugins.": ["Apple TV では Android のプラグインを実行できません。", "Apple TV에서는 Android 플러그인을 실행할 수 없습니다.", "Apple TV 無法執行 Android 外掛。"],
  "No JVM, no WebView, no APKs.": ["JVM も WebView も APK もありません。", "JVM도, WebView도, APK도 없습니다.", "沒有 JVM、沒有 WebView，也不能裝 APK。"],
  "OK": ["OK", "확인", "好"],
  "TVBox subscriptions are JSON files written for Android TV boxes.": ["TVBox の配信設定は、Android TV ボックス向けに書かれた JSON ファイルです。", "TVBox 구독은 Android TV 박스용으로 작성된 JSON 파일입니다.", "TVBox 訂閱是為 Android 電視盒撰寫的 JSON 檔案。"],
  "Yingxia reads the same subscriptions, natively, on Apple TV.": ["映匣は同じ配信設定を、Apple TV でネイティブに読み込みます。", "Yingxia는 같은 구독을 Apple TV에서 네이티브로 읽어 들입니다.", "映匣在 Apple TV 上原生讀取同一份訂閱。"],

  // Settings
  "Settings": ["設定", "설정", "設定"],
  "Sources": ["ソース", "소스", "片源"],
  "Runtime": ["ランタイム", "런타임", "執行環境"],
  "Language": ["言語", "언어", "語言"],
  "About": ["情報", "정보", "關於"],
  "Add Subscription": ["配信設定を追加", "구독 추가", "新增訂閱"],
  "Add": ["追加", "추가", "新增"],
  "Loading subscription…": ["配信設定を読み込み中…", "구독 불러오는 중…", "正在載入訂閱…"],
  "sites": ["サイト", "사이트", "站點"],
  "live channels": ["ライブチャンネル", "실시간 채널", "直播頻道"],
  "parsers": ["パーサー", "파서", "解析器"],
  "Refresh failed · kept the last working copy": ["更新に失敗 · 最後に動いていた内容を保持", "새로 고침 실패 · 마지막으로 작동한 내용 유지", "更新失敗 · 保留最後一次可用的內容"],
  "Add your subscription once, by URL.": ["配信設定は URL で一度追加するだけ。", "구독은 URL로 한 번만 추가하세요.", "只要用網址加入一次訂閱。"],
  "Yingxia loads every site, live list and parser inside it.": ["映匣がその中のサイト、ライブリスト、パーサーをすべて読み込みます。", "Yingxia가 그 안의 모든 사이트, 실시간 목록, 파서를 불러옵니다.", "映匣會載入其中所有站點、直播清單與解析器。"],
  "If a refresh ever fails, the last working copy stays.": ["更新に失敗しても、最後に動いていた内容は残ります。", "새로 고침에 실패해도 마지막으로 작동한 내용은 남습니다.", "就算更新失敗，最後一次可用的內容也會保留。"],

  // Runtime
  "Source": ["ソース", "소스", "片源"],
  "Runs on device in": ["デバイス上の実行環境", "기기에서 실행", "在裝置上執行於"],
  "Same screens for every source": ["どのソースも同じ画面で", "모든 소스에 같은 화면", "每個片源都是同樣的畫面"],
  "JAR spider": ["JAR スパイダー", "JAR 스파이더", "JAR 爬蟲"],
  "native": ["ネイティブ", "네이티브", "原生"],
  "in-process": ["プロセス内", "프로세스 내", "行程內"],
  "Lite JS port": ["軽量 JS 版", "경량 JS 포트", "輕量 JS 版"],
  "↳ JAR fallback": ["↳ JAR にフォールバック", "↳ JAR로 대체", "↳ JAR 備援"],
  "Home": ["ホーム", "홈", "首頁"],
  "Categories": ["カテゴリー", "카테고리", "分類"],
  "Search": ["検索", "검색", "搜尋"],
  "Playback": ["再生", "재생", "播放"],
  "Each source runs on the device, in the runtime it needs.": ["各ソースは、必要なランタイムでデバイス上で動きます。", "각 소스는 필요한 런타임으로 기기에서 실행됩니다.", "每個片源都在裝置上，以它需要的執行環境運行。"],
  "Lightweight JavaScript ports go first. The original plugin is the fallback.": ["軽量な JavaScript 版を優先し、元のプラグインはフォールバックに。", "가벼운 JavaScript 포트를 먼저, 원래 플러그인은 대체 수단으로.", "優先使用輕量 JavaScript 版，原始外掛作為備援。"],

  // Sources
  "Every source gets its own shelf: categories, pages and filters.": ["ソースごとに専用の棚。カテゴリー、ページ、フィルターも。", "소스마다 자신만의 진열대: 카테고리, 페이지, 필터.", "每個片源都有自己的片架：分類、分頁與篩選。"],
  "All of it, driven by the Siri Remote.": ["すべて Siri Remote で操作できます。", "모두 Siri Remote로 조작합니다.", "全部用 Siri Remote 操作。"],

  // Search
  "Global Search": ["横断検索", "통합 검색", "全域搜尋"],
  "results": ["件", "건", "筆結果"],
  "Sources answered": ["応答したソース", "응답한 소스", "已回應片源"],
  "waiting…": ["待機中…", "대기 중…", "等待中…"],
  "Less than a minute left": ["残り 1 分未満", "1분 미만 남음", "剩不到一分鐘"],
  "One search runs across every source in your subscription.": ["ひとつの検索で、配信設定内のすべてのソースを探します。", "한 번의 검색으로 구독의 모든 소스를 찾습니다.", "一次搜尋，就能找遍訂閱中的所有片源。"],
  "Results appear as each source answers. Slow ones never hold up the rest.": ["結果はソースが応答した順に表示。遅いソースが全体を止めることはありません。", "결과는 소스가 응답하는 대로 표시됩니다. 느린 소스가 나머지를 막지 않습니다.", "結果隨各片源回應陸續出現，慢的片源不會拖住其他。"],

  // Player
  "Player": ["プレーヤー", "플레이어", "播放器"],
  "Episode 1 ·": ["第1話 ·", "1화 ·", "第 1 集 ·"],
  "Couldn’t play this video.": ["この動画を再生できませんでした。", "이 동영상을 재생할 수 없습니다.", "無法播放這部影片。"],
  "The source returned an expired link.": ["ソースが期限切れのリンクを返しました。", "소스가 만료된 링크를 반환했습니다.", "片源回傳了已過期的連結。"],
  "Retry": ["再試行", "재시도", "重試"],
  "Back": ["戻る", "뒤로", "返回"],
  "▶ Playing": ["▶ 再生中", "▶ 재생 중", "▶ 播放中"],
  "Video plays through Apple’s own AVPlayer, with HLS.": ["動画は Apple の AVPlayer で再生。HLS にも対応。", "동영상은 Apple의 AVPlayer로 재생되며 HLS를 지원합니다.", "影片透過 Apple 自家的 AVPlayer 播放，支援 HLS。"],
  "When a link fails you get a clear screen and Retry, not an endless spinner.": ["リンクが切れても、終わらない読み込みではなく、わかりやすい画面と再試行ボタンを。", "링크가 실패하면 끝없는 로딩 대신 명확한 화면과 재시도 버튼이 나타납니다.", "連結失效時，你會看到清楚的畫面和重試按鈕，而不是轉不停的圈圈。"],

  // Live TV
  "Live TV": ["ライブ TV", "실시간 TV", "直播電視"],
  "Playlists": ["プレイリスト", "재생 목록", "播放清單"],
  "188 channels": ["188 チャンネル", "188개 채널", "188 個頻道"],
  "42 channels": ["42 チャンネル", "42개 채널", "42 個頻道"],
  "Groups": ["グループ", "그룹", "分組"],
  "All": ["すべて", "전체", "全部"],
  "Favorites": ["お気に入り", "즐겨찾기", "收藏"],
  "Bring M3U or TXT playlists. Channels are laid out like a TV guide.": ["M3U や TXT のプレイリストを読み込み、チャンネルを番組ガイドのように並べます。", "M3U 또는 TXT 재생 목록을 불러오면 채널이 편성표처럼 정리됩니다.", "匯入 M3U 或 TXT 播放清單，頻道像節目表一樣排好。"],
  "Search channels and keep your favorites close.": ["チャンネルを検索し、お気に入りを手元に。", "채널을 검색하고 즐겨찾기를 가까이 두세요.", "搜尋頻道，常看的加入收藏。"],

  // Every screen
  "Every screen": ["すべての画面で", "모든 화면", "所有螢幕"],
  "No account": ["アカウント不要", "계정 없음", "免帳號"],
  "No analytics": ["解析なし", "분석 없음", "無分析追蹤"],
  "Stays on device": ["データはデバイス内", "기기에만 저장", "資料留在裝置上"],
  "Logs redact secrets": ["ログの秘密情報は伏せ字", "로그의 비밀 정보 가림", "日誌遮蔽機密"],
  "One app for Apple TV, iPhone, iPad and Mac.": ["Apple TV、iPhone、iPad、Mac にひとつのアプリで。", "Apple TV, iPhone, iPad, Mac을 위한 하나의 앱.", "一個 App，支援 Apple TV、iPhone、iPad 與 Mac。"],
  "No account and no analytics. Everything stays on your device.": ["アカウントも解析もなし。すべてがデバイス内に残ります。", "계정도 분석도 없습니다. 모든 것이 기기에 남습니다.", "無需帳號、沒有分析追蹤，一切都留在你的裝置上。"],

  // Controls and page chrome
  "Play": ["再生", "재생", "播放"],
  "Pause": ["一時停止", "일시정지", "暫停"],
  "Replay": ["もう一度", "다시 보기", "重播"],
  "Seek": ["再生位置", "탐색", "播放位置"],
  "Yingxia introduction film": ["映匣の紹介動画", "Yingxia 소개 영상", "映匣介紹影片"],
  "How it works": ["仕組み", "작동 방식", "運作方式"],
  "How Yingxia works": ["映匣の仕組み", "Yingxia 작동 방식", "映匣如何運作"],
};

const COL: Record<Exclude<Lang, "en">, number> = { ja: 0, ko: 1, "zh-Hant": 2 };

/** The film string `en` in `lang`, or `en` itself when there is no translation. */
export function tr(lang: Lang, en: string): string {
  return lang === "en" ? en : T[en]?.[COL[lang]] ?? en;
}

export function translateFilm(root: HTMLElement, lang: Lang) {
  if (lang === "en") return;
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const [, lead, text, trail] = /^(\s*)([\s\S]*?)(\s*)$/.exec(n.nodeValue ?? "")!;
    if (!text) continue;
    const out = tr(lang, text);
    if (out === text) continue;
    n.nodeValue = lead + out + trail;
    // Typed lines step once per character.
    n.parentElement?.closest<HTMLElement>(".type")?.style.setProperty("--n", String([...out].length));
  }
  for (const el of root.querySelectorAll<HTMLElement>("[data-ch]")) el.dataset.ch = tr(lang, el.dataset.ch ?? "");
  for (const el of root.querySelectorAll<HTMLElement>("[aria-label]")) el.setAttribute("aria-label", tr(lang, el.getAttribute("aria-label")!));
}
