import { useI18n } from "../i18n/I18nProvider";
import { INSTALL } from "../i18n/install-strings";
import { Brand, LanguageSelect, DownloadMac } from "./controls";

export function Nav() {
  const { t, lang } = useI18n();
  return (
    <header className="nav">
      <div className="nav-inner">
        <Brand />
        <nav className="nav-links">
          <a href="#features">{t("nav.features")}</a>
          <a href="#install">{INSTALL[lang].nav}</a>
          <a href="#faq">{t("nav.faq")}</a>
        </nav>
        <div className="nav-actions">
          <LanguageSelect />
          <DownloadMac small />
        </div>
      </div>
    </header>
  );
}
