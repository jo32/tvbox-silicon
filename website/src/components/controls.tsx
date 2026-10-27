import { SFSymbol } from "./SFSymbol";
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

/** The current Mac release on download.getmegaportal.com (R2 bucket megaportal-downloads): Apple silicon, and Intel. */
export const MAC_DOWNLOAD = "https://download.getmegaportal.com/yingxia/1.8.1/Yingxia-1.8.1-macos-arm64.dmg";
export const MAC_INTEL_DOWNLOAD = "https://download.getmegaportal.com/yingxia/1.8.1/Yingxia-1.8.1-macos-x86_64.dmg";

/** iPhone/iPad and Apple TV IPAs for sideloading, next to the Mac release. */
export const DOWNLOADS = {
  mac: MAC_DOWNLOAD,
  ios: "https://download.getmegaportal.com/yingxia/1.8.1/Yingxia-1.8.1-ios.ipa",
  tv: "https://download.getmegaportal.com/yingxia/1.8.1/Yingxia-1.8.1-tvos.ipa",
} as const;

/** Public TestFlight invites (external testing), the recommended install for iPhone, iPad and Apple TV.
 * Their QR codes are public/testflight/{ios,tv}.svg; rerun scripts/testflight-qr.py when a link changes. */
export const TESTFLIGHT = {
  ios: "https://testflight.apple.com/join/dU6UNbzp",
  tv: "https://testflight.apple.com/join/SSgWEwSr",
} as const;

/** Apple's TestFlight app on the App Store (the same listing for iPhone, iPad and Apple TV). */
export const TESTFLIGHT_APP = "https://apps.apple.com/app/testflight/id899247664";

/** Sideloading tools, official sources only (iloader.site and plamimpactor.site are third-party mirrors). */
export const CIDER = "https://github.com/Battzz/cider-cli";
export const IMPACTOR = "https://github.com/claration/Impactor/releases";
export const ILOADER = "https://iloader.app";
export const SIDELOADLY = "https://sideloadly.io/";

/** AI agents that can run the install (they run commands on the computer), by their official pages.
 * `cjk` is the name in Chinese and Japanese. */
export const AGENTS: { name: string; cjk?: string; href: string }[] = [
  { name: "Claude Code", href: "https://claude.com/product/claude-code" },
  { name: "WorkBuddy", href: "https://www.workbuddy.ai" },
  { name: "Doubao", cjk: "豆包", href: "https://www.doubao.com/download" },
  { name: "Grok Build", href: "https://x.ai/news/grok-build-cli" },
  { name: "Gemini CLI", href: "https://github.com/google-gemini/gemini-cli" },
  { name: "Codex", href: "https://developers.openai.com/codex" },
];

/** The app's public source repository (GPL-3.0). */
export const REPO = "https://github.com/jo32/tvbox-silicon";

/** The Telegram group where users talk with the developer and each other. */
export const TELEGRAM = "https://t.me/+knKAmySfMycyMzg5";

/** The full install guide (with troubleshooting) in the public repository. */
export const INSTALL_GUIDE = `${REPO}/blob/main/Docs/INSTALL.md`;

/** The agent skill the "copy prompt" points AI agents at (raw, so agents read plain Markdown). */
export const INSTALL_SKILL = `${REPO.replace("https://github.com/", "https://raw.githubusercontent.com/")}/main/.agents/skills/install-yingxia/SKILL.md`;

/** Goes to the install section, which offers the Mac download and the iPhone, iPad and Apple TV IPAs. */
export function DownloadButton({ small = false }: { small?: boolean }) {
  const { t } = useI18n();
  return (
    <a className={small ? "pill pill-dark pill-sm" : "pill pill-dark"} href="#install">
      <SFSymbol name="arrow.down.circle.fill" />
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
      <SFSymbol name="chevron.up.chevron.down" />
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
