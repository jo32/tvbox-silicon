import { useI18n } from "../i18n/I18nProvider";
import { LANGS, LOCALES, type Lang } from "../i18n/strings";
import { LANG_PATH } from "../site";

/** The "Coming soon" pill that stands in for a download button until launch. */
export function SoonPill({ small = false }: { small?: boolean }) {
  const { t } = useI18n();
  return (
    <span className={small ? "pill pill-dark pill-sm pill-soon" : "pill pill-dark pill-soon"}>
      <span className="dot" aria-hidden="true" />
      {t("soon")}
    </span>
  );
}

/** The current Mac release on download.getmegaportal.com (R2 bucket megaportal-downloads). */
export const MAC_DOWNLOAD = "https://download.getmegaportal.com/yingxia/1.0.1/Yingxia-1.0.1-macos-arm64.dmg";

/** iPhone/iPad and Apple TV IPAs for sideloading, next to the Mac release. */
export const DOWNLOADS = {
  mac: MAC_DOWNLOAD,
  ios: "https://download.getmegaportal.com/yingxia/1.0.1/Yingxia-1.0.1-ios.ipa",
  tv: "https://download.getmegaportal.com/yingxia/1.0.1/Yingxia-1.0.1-tvos.ipa",
} as const;

export const SIDELOADLY = "https://sideloadly.io/";

/** The app's public source repository (GPL-3.0). */
export const REPO = "https://github.com/jo32/tvbox-silicon";

/** The full Sideloadly guide (with troubleshooting) in the public repository. */
export const INSTALL_GUIDE = `${REPO}/blob/main/Docs/INSTALL.md`;

/** Goes to the install section, which offers the Mac download and the iPhone, iPad and Apple TV IPAs. */
export function DownloadButton({ small = false }: { small?: boolean }) {
  const { t } = useI18n();
  return (
    <a className={small ? "pill pill-dark pill-sm" : "pill pill-dark"} href="#install">
      <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 4v11M7 10l5 5 5-5M5 20h14" /></svg>
      {t("dl.mac")}
    </a>
  );
}

export function LanguageSelect() {
  const { lang, setLang, t } = useI18n();
  return (
    <label className="select">
      <span className="sr">{t("footer.lang")}</span>
      <select className="lang-select" value={lang} onChange={(e) => setLang(e.target.value as Lang)}>
        {LANGS.map((code) => (
          <option key={code} value={code} lang={code}>
            {LOCALES[code].name}
          </option>
        ))}
      </select>
    </label>
  );
}

/** GitHub link to the source; `label` shows text next to the mark, otherwise it is icon-only. */
export function GitHubLink({ label }: { label?: string }) {
  const { t } = useI18n();
  return (
    <a className="gh-link" href={REPO} target="_blank" rel="noreferrer" aria-label={label ? undefined : t("footer.source")} title={label ? undefined : t("footer.source")}>
      <svg viewBox="0 0 16 16" width="18" height="18" aria-hidden="true" fill="currentColor">
        <path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z" />
      </svg>
      {label && <span>{label}</span>}
    </a>
  );
}

export function Brand({ size = 28 }: { size?: number }) {
  const { t, lang } = useI18n();
  return (
    <a className="brand" href={LANG_PATH[lang]}>
      <img src="/assets/icon-192.png" alt="" width={size} height={size} />
      <span>{t("brand")}</span>
    </a>
  );
}
