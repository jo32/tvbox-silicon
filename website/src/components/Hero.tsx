import { useI18n } from "../i18n/I18nProvider";
import { DownloadMac } from "./controls";
import { Headline } from "./Headline";
import { HeroFilm } from "./HeroFilm";
import { Reveal } from "./Reveal";

export function Hero() {
  const { t, lang } = useI18n();
  return (
    <section className="hero">
      <div className="badge">
        <img src="/assets/icon-192.png" alt="" width={20} height={20} />
        <span>{t("hero.badge")}</span>
      </div>
      <Headline as="h1" lines={["hero.l1", "hero.l2"]} animate />
      <p className="lead">{t("hero.sub")}</p>
      <div className="actions">
        <DownloadMac />
        <a className="link" href="#features">
          {t("hero.more")} <span aria-hidden="true">↓</span>
        </a>
      </div>
      <p className="meta">{t("dl.req")}</p>
      <Reveal className="hero-stage hero-film">
        <HeroFilm />
        <a className="link hero-film-link" href={`/intro/?lang=${lang}`}>
          {t("hero.film")} <span aria-hidden="true">→</span>
        </a>
      </Reveal>
    </section>
  );
}
