import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
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

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(detectLang);
  const locale = LOCALES[lang];

  const setLang = useCallback((next: Lang) => {
    setLangState(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // Not persisted; the choice still applies to this visit.
    }
    const url = new URL(location.href);
    url.searchParams.set("lang", next);
    history.replaceState(null, "", url);
  }, []);

  useEffect(() => {
    document.documentElement.lang = lang;
    document.title = locale.text["meta.title"];
    document.querySelector('meta[name="description"]')?.setAttribute("content", locale.text["meta.description"]);
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
