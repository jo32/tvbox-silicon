import type { Lang } from "./i18n/strings";

export const SITE_URL = "https://yingxia.getmegaportal.com";

// Each language has its own page so search engines can index it; the build prerenders all four.
// The root page is English, and also switches to a saved or browser language once the app loads.
export const LANG_PATH: Record<Lang, string> = {
  en: "/",
  ja: "/ja/",
  ko: "/ko/",
  "zh-Hant": "/zh-hant/",
};

/** The language a /ja/-style path names, or null for the root and every other page. */
export function pathLang(pathname: string): Lang | null {
  const path = pathname.toLowerCase().replace(/\/?$/, "/");
  if (path === "/") return null;
  const match = Object.entries(LANG_PATH).find(([, p]) => p === path);
  return match ? (match[0] as Lang) : null;
}

/** Whether the path is the homepage in some language (/, /ja/, ...), rather than /intro/. */
export const isHomePath = (pathname: string) => pathname === "/" || pathLang(pathname) !== null;
