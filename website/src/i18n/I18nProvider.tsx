import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { isHomePath, LANG_PATH, SITE_URL } from "../site";
import { detectLang, STORAGE_KEY } from "./detect";
import { LOCALES, type Lang, type Locale, type TextKey } from "./strings";

interface I18n {
  lang: Lang;
  locale: Locale;
  t: (key: TextKey) => string;
  shot: (name: string) => string;
  setLang: (lang: Lang) => void;
}

const I18nContext = createContext<I18n | null>(null);

interface Props {
  /** The language the page was prerendered in. It renders first, so hydration matches, then the detected language takes over. */
  renderedLang?: Lang;
  children: ReactNode;
}

export function I18nProvider({ renderedLang, children }: Props) {
  const [lang, setLangState] = useState<Lang>(() => renderedLang ?? detectLang());
  const locale = LOCALES[lang];

  useEffect(() => {
    if (renderedLang) setLangState(detectLang());
  }, [renderedLang]);

  const setLang = useCallback((next: Lang) => {
    setLangState(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // Not persisted; the choice still applies to this visit.
    }
  }, []);

  useEffect(() => {
    document.documentElement.lang = lang;
    document.title = locale.text["meta.title"];
    document.querySelector('meta[name="description"]')?.setAttribute("content", locale.text["meta.description"]);
    // Keep the address on the language's own page (/ja/), which also replaces the old ?lang= links.
    if (!isHomePath(location.pathname)) return;
    const url = new URL(location.href);
    url.pathname = LANG_PATH[lang];
    url.searchParams.delete("lang");
    if (url.href !== location.href) history.replaceState(null, "", url);
    document.querySelector('link[rel="canonical"]')?.setAttribute("href", SITE_URL + LANG_PATH[lang]);
  }, [lang, locale]);

  const value = useMemo<I18n>(
    () => ({
      lang,
      locale,
      t: (key) => locale.text[key],
      shot: (name) => `/screenshots/${locale.shots}/${name}.jpg`,
      setLang,
    }),
    [lang, locale, setLang],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18n {
  const value = useContext(I18nContext);
  if (!value) throw new Error("useI18n must be used inside <I18nProvider>");
  return value;
}
