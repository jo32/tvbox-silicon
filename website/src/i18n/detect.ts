import { LANGS, type Lang } from "./strings";

export const STORAGE_KEY = "yx-lang";

export const isLang = (value: string | null): value is Lang => LANGS.includes(value as Lang);

// ?lang= wins, then a saved choice, then the browser's preferred languages.
export function detectLang(): Lang {
  const param = new URLSearchParams(location.search).get("lang");
  if (isLang(param)) return param;
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (isLang(saved)) return saved;
  } catch {
    // Storage can be unavailable (private mode, blocked cookies).
  }
  for (const tag of navigator.languages ?? [navigator.language]) {
    const t = tag.toLowerCase();
    if (t.startsWith("ja")) return "ja";
    if (t.startsWith("ko")) return "ko";
    if (t.startsWith("zh")) return "zh-Hant";
    if (t.startsWith("en")) return "en";
  }
  return "en";
}
