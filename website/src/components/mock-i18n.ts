// UI labels in the device mockups (mock-screens.tsx), in the app's own wording: Japanese and Traditional
// Chinese come from Sources/TVCore/Resources/*.lproj/Localizable.strings; the app has no Korean yet.
// Titles, sources and categories stay as a Chinese TVBox subscription serves them.
import { useCallback } from "react";
import { useI18n } from "../i18n/I18nProvider";
import type { Lang } from "../i18n/strings";

type Row = [ja: string, ko: string, zhHant: string];

const T: Record<string, Row> = {
  "Watch Now": ["今すぐ観る", "지금 보기", "立即觀看"],
  "Live TV": ["ライブ TV", "실시간 TV", "直播"],
  "Global Search": ["横断検索", "통합 검색", "全域搜尋"],
  "Sources": ["配信ソース", "소스", "隨選來源"],
  "Favorites": ["お気に入り", "즐겨찾기", "收藏"],
  "Downloads": ["ダウンロード", "다운로드", "下載"],
  "Settings": ["設定", "설정", "設定"],
  "Browse": ["ブラウズ", "둘러보기", "瀏覽"],
  "Library": ["ライブラリ", "보관함", "資料庫"],
  "More": ["その他", "더 보기", "更多"],
  "Recommendations": ["おすすめ", "추천", "推薦"],
  "Search channels": ["チャンネルを検索", "채널 검색", "搜尋頻道"],
  "All": ["すべて", "전체", "全部"],
  "Channels: 188": ["チャンネル数：188", "채널: 188", "頻道數：188"],
  "Search videos": ["動画を検索", "동영상 검색", "搜尋影片"],
  "Page 1 of 50": ["1 / 50 ページ", "1 / 50 페이지", "第 1 / 50 頁"],
  "Searched 20 of 31 sources": ["20 / 31 ソースを検索済み", "31개 중 20개 소스 검색됨", "已搜尋 20 / 31 個來源"],
  "325 results": ["325 件の結果", "결과 325개", "325 個結果"],
  "All Sources": ["すべてのソース", "모든 소스", "全部來源"],
  "Stop": ["停止", "정지", "停止"],
  "SPACE": ["スペース", "스페이스", "空格"],
  "Version 1.8.2": ["バージョン 1.8.2", "버전 1.8.2", "版本 1.8.2"],
};

const COL: Record<Exclude<Lang, "en">, number> = { ja: 0, ko: 1, "zh-Hant": 2 };

/** `m(en)`: a mockup label in the page language, or `en` itself when there is no translation. */
export function useMockText() {
  const { lang } = useI18n();
  return useCallback((en: string) => (lang === "en" ? en : (T[en]?.[COL[lang]] ?? en)), [lang]);
}
