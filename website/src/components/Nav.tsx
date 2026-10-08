import { useI18n } from "../i18n/I18nProvider";
import { Brand, LanguageSelect, DownloadMac } from "./controls";

export function Nav() {
  const { t } = useI18n();
  return (
    <header className="nav">
      <div className="nav-inner">
        <Brand />
        <nav className="nav-links">
          <a href="#features">{t("nav.features")}</a>
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
