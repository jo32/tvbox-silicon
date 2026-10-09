import { useEffect, useState, type ComponentType } from "react";
import { useI18n } from "../i18n/I18nProvider";
import { INSTALL, type Platform } from "../i18n/install-strings";
import { DOWNLOADS, INSTALL_GUIDE, SIDELOADLY } from "./controls";
import { AppleTVArt, IPhoneIPadArt, MacBookArt } from "./devices";
import { Reveal } from "./Reveal";

const PLATFORMS: { id: Platform; Art: ComponentType }[] = [
  { id: "mac", Art: MacBookArt },
  { id: "ios", Art: IPhoneIPadArt },
  { id: "tv", Art: AppleTVArt },
];

// Links like /#install-tv open a specific tab.
function hashPlatform(): Platform | null {
  const match = /^#install-(mac|ios|tv)$/.exec(location.hash);
  return match ? (match[1] as Platform) : null;
}

// iPadOS reports itself as a Mac, so only phones and older iPads land on the iOS tab.
function initialPlatform(): Platform {
  return hashPlatform() ?? (/iPhone|iPad|iPod/.test(navigator.userAgent) ? "ios" : "mac");
}

const DownloadGlyph = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 4v11M7 10l5 5 5-5M5 20h14" />
  </svg>
);

export function Install() {
  const { lang } = useI18n();
  const copy = INSTALL[lang];
  const [platform, setPlatform] = useState<Platform>(initialPlatform);
  const sideload = platform !== "mac";

  useEffect(() => {
    const onHash = () => {
      const next = hashPlatform();
      if (next) setPlatform(next);
    };
    addEventListener("hashchange", onHash);
    return () => removeEventListener("hashchange", onHash);
  }, []);

  return (
    <section className="section install" id="install">
      <Reveal>
        <h2 className="headline small">
          <span className="sans">{copy.l1}</span>
          <span className="serif">{copy.l2}</span>
        </h2>
      </Reveal>
      <Reveal as="p" className="lead">
        {copy.sub}
      </Reveal>

      <Reveal>
        <div className="device-picker" role="tablist" aria-label={copy.nav}>
        {PLATFORMS.map(({ id, Art }) => (
          <button
            key={id}
            type="button"
            role="tab"
            id={`install-${id}`}
            aria-selected={platform === id}
            aria-controls="install-panel"
            className={platform === id ? "device on" : "device"}
            onClick={() => setPlatform(id)}
          >
            <span className="device-art">
              <Art />
            </span>
            <span className="device-name">{copy.device[id]}</span>
            <span className="device-req">{copy.req[id]}</span>
            <span className={id === "mac" ? "device-tag signed" : "device-tag"}>{copy.tag[id]}</span>
          </button>
        ))}
        </div>
      </Reveal>

      <div className={`install-panel tone-${platform}`} id="install-panel" role="tabpanel" aria-labelledby={`install-${platform}`}>
        <div className="install-actions">
          <a className="pill pill-light" href={DOWNLOADS[platform]}>
            <DownloadGlyph />
            {copy.dl[platform]}
          </a>
          {sideload && (
            <a className="pill pill-glass" href={SIDELOADLY} target="_blank" rel="noreferrer">
              {copy.sideloadly} <span aria-hidden="true">↗</span>
            </a>
          )}
        </div>

        <ol className="steps" key={platform}>
          {copy.steps[platform].map((step, i) => (
            <li className="step" key={i} style={{ animationDelay: `${i * 70}ms` }}>
              <span className="step-n">{i + 1}</span>
              <h4>{step.t}</h4>
              <p>{step.b}</p>
            </li>
          ))}
        </ol>

        {sideload && (
          <div className="keep">
            <div className="keep-text">
              <h4>{copy.keep.t}</h4>
              <p>{copy.keep.b}</p>
              <p className="keep-tip">{copy.keep.tip}</p>
            </div>
            <div className="keep-bars">
              <div className="bar-row">
                <span>{copy.keep.free}</span>
                <b>{copy.keep.freeTime}</b>
                <i className="bar"><i style={{ width: `${(7 / 365) * 100}%` }} /></i>
              </div>
              <div className="bar-row">
                <span>{copy.keep.paid}</span>
                <b>{copy.keep.paidTime}</b>
                <i className="bar"><i style={{ width: "100%" }} /></i>
              </div>
            </div>
          </div>
        )}

        {sideload && (
          <a className="install-guide" href={INSTALL_GUIDE} target="_blank" rel="noreferrer">
            {copy.guide} <span aria-hidden="true">→</span>
          </a>
        )}
      </div>
    </section>
  );
}
