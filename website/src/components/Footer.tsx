import { useI18n } from "../i18n/I18nProvider";
import { Brand, DownloadButton, GitHubLink, LanguageSelect } from "./controls";
import { Headline } from "./Headline";
import { Reveal } from "./Reveal";

export function ClosingCta() {
  const { t } = useI18n();
  return (
    <Reveal as="section" className="section cta">
      <img className="cta-icon" src="/assets/icon-512.png" alt="" width={96} height={96} />
      <Headline lines={["cta.l1", "cta.l2"]} small />
      <p className="lead">{t("cta.sub")}</p>
      <div className="actions">
        <DownloadButton />
      </div>
    </Reveal>
  );
}

export function Footer() {
  const { t } = useI18n();
  return (
    <footer className="footer">
      <div className="footer-inner">
        <div className="footer-top">
          <Brand size={24} />
          <span className="copyright" suppressHydrationWarning>
            © {new Date().getFullYear()}
          </span>
          <GitHubLink label={t("footer.source")} />
          <LanguageSelect />
        </div>
        <p className="disclaimer">{t("footer.disclaimer")}</p>
      </div>
    </footer>
  );
}
