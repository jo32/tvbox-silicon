import { useI18n } from "../i18n/I18nProvider";
import { LANGS, LOCALES, type Lang } from "../i18n/strings";

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

/** The full Sideloadly guide (with troubleshooting) in the public repository. */
export const INSTALL_GUIDE = "https://github.com/jo32/tvbox-silicon/blob/main/Docs/INSTALL.md";

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

export function Brand({ size = 28 }: { size?: number }) {
  const { t } = useI18n();
  return (
    <a className="brand" href="/">
      <img src="/assets/icon-192.png" alt="" width={size} height={size} />
      <span>{t("brand")}</span>
    </a>
  );
}
