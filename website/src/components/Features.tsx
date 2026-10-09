import { useI18n } from "../i18n/I18nProvider";
import type { TextKey } from "../i18n/strings";
import { Headline } from "./Headline";
import { Reveal } from "./Reveal";
import { Stage } from "./Stage";

interface Feature {
  shot: string;
  title: TextKey;
  body: TextKey;
}

const FEATURES: Feature[] = [
  { shot: "live", title: "c.live.t", body: "c.live.b" },
  { shot: "search", title: "c.search.t", body: "c.search.b" },
  { shot: "site", title: "c.site.t", body: "c.site.b" },
];

export function Features() {
  const { t, locale } = useI18n();
  return (
    <section className="section" id="features">
      <Reveal>
        <Headline lines={["sec.l1", "sec.l2"]} small />
      </Reveal>
      <Reveal as="p" className="lead">
        {t("sec.sub")}
      </Reveal>
      <Reveal as="ul" className="chips">
        {locale.chips.map((chip) => (
          <li key={chip}>{chip}</li>
        ))}
      </Reveal>

      {FEATURES.map(({ shot, title, body }) => (
        <Reveal as="article" className="card" key={shot}>
          <h3>{t(title)}</h3>
          <p>{t(body)}</p>
          <Stage shot={shot} alt={t(title)} />
        </Reveal>
      ))}
      {t("shots.note") && <p className="note">{t("shots.note")}</p>}
    </section>
  );
}
