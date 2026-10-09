import { useEffect, useState, type ComponentType } from "react";
import { useI18n } from "../i18n/I18nProvider";
import { INSTALL, type Platform } from "../i18n/install-strings";
import { DOWNLOADS, INSTALL_GUIDE, SIDELOADLY } from "./controls";
import { AppleTVArt, DevicesIcon, IPhoneIPadArt, MacBookArt, MacIcon, TVIcon } from "./devices";
import { Reveal } from "./Reveal";

const PLATFORMS: { id: Platform; Icon: ComponentType; Art: ComponentType<{ shot: string }> }[] = [
  { id: "mac", Icon: MacIcon, Art: MacBookArt },
  { id: "ios", Icon: DevicesIcon, Art: IPhoneIPadArt },
  { id: "tv", Icon: TVIcon, Art: AppleTVArt },
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

export function Install() {
  const { lang, shot } = useI18n();
  const copy = INSTALL[lang];
  const [platform, setPlatform] = useState<Platform>(initialPlatform);
  const sideload = platform !== "mac";
  const Art = PLATFORMS.find((p) => p.id === platform)!.Art;

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
        <div className="tabnav" role="tablist" aria-label={copy.nav}>
          {PLATFORMS.map(({ id, Icon }) => (
            <button
              key={id}
              type="button"
              role="tab"
              id={`install-${id}`}
              aria-selected={platform === id}
              aria-controls="install-panel"
              className={platform === id ? "tab on" : "tab"}
              onClick={() => setPlatform(id)}
            >
              <Icon />
              <span>{copy.device[id]}</span>
            </button>
          ))}
        </div>
      </Reveal>

      <div className="install-panel" id="install-panel" role="tabpanel" aria-labelledby={`install-${platform}`}>
        <div className="showcase" key={platform}>
          <div className="showcase-art">
            <Art shot={shot("home")} />
          </div>
          <p className={sideload ? "eyebrow" : "eyebrow signed"}>{copy.tag[platform]}</p>
          <h3 className="product">{copy.title[platform]}</h3>
          <p className="product-req">{copy.req[platform]}</p>
          <div className="product-actions">
            <a className="btn-blue" href={DOWNLOADS[platform]}>
              {copy.get}
            </a>
            {sideload && (
              <a className="link-blue" href={SIDELOADLY} target="_blank" rel="noreferrer">
                {copy.sideloadly} <span aria-hidden="true">›</span>
              </a>
            )}
          </div>
        </div>

        <div className="how">
          <h3 className="how-title">{copy.how}</h3>
          <ol className={`steps n${copy.steps[platform].length}`} key={platform}>
            {copy.steps[platform].map((step, i) => (
              <li className="step" key={i}>
                <span className="step-n">{i + 1}</span>
                <h4>{step.t}</h4>
                <p>{step.b}</p>
              </li>
            ))}
          </ol>
        </div>

        {sideload && (
          <div className="keep">
            <h3 className="how-title">{copy.keep.t}</h3>
            <div className="keep-stats">
              <div className="stat">
                <span className="stat-value">{copy.keep.freeTime}</span>
                <span className="stat-label">{copy.keep.free}</span>
              </div>
              <div className="stat">
                <span className="stat-value">{copy.keep.paidTime}</span>
                <span className="stat-label">{copy.keep.paid}</span>
              </div>
            </div>
            <p className="keep-body">
              {copy.keep.b} {copy.keep.tip}
            </p>
            <a className="link-blue" href={INSTALL_GUIDE} target="_blank" rel="noreferrer">
              {copy.guide} <span aria-hidden="true">›</span>
            </a>
          </div>
        )}
      </div>
    </section>
  );
}
