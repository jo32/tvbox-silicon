import { useEffect, useRef } from "react";
import { useI18n } from "../i18n/I18nProvider";
import { mountFilm } from "../intro/film";

// A static import on purpose: a dynamic import() made the bundler put its namespace helper in
// the homepage chunk, so /intro/ loaded the homepage app too and crashed on the missing #root.

/** The intro film in the hero. */
export function HeroFilm() {
  const { lang } = useI18n();
  const host = useRef<HTMLDivElement>(null);

  useEffect(() => (host.current ? mountFilm(host.current, { lang }) : undefined), [lang]);

  return <div ref={host} className="hero-film-host" />;
}
