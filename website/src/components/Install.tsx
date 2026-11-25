import { SFSymbol } from "./SFSymbol";
import { useEffect, useRef, useState, type ComponentType } from "react";
import { useI18n } from "../i18n/I18nProvider";
import { INSTALL, type InstallCopy, type Mode, type Platform, type Sideload } from "../i18n/install-strings";
import { AGENTS, CIDER, DOWNLOADS, ILOADER, IMPACTOR, INSTALL_GUIDE, INSTALL_SKILL, MAC_INTEL_DOWNLOAD, SIDELOADLY, TESTFLIGHT, TESTFLIGHT_APP } from "./controls";
import { AppleTVIcon, IPhoneIPadIcon, MacIcon } from "./icons-devices";
import { Reveal } from "./Reveal";

const PLATFORMS: { id: Platform; Icon: ComponentType }[] = [
  { id: "mac", Icon: MacIcon },
  { id: "ios", Icon: IPhoneIPadIcon },
  { id: "tv", Icon: AppleTVIcon },
];

/** Ways to install, recommended first: TestFlight, then the sideloading modes. */
const MODES: { id: Mode; icon: string }[] = [
  { id: "testflight", icon: "arrow.down.circle" },
  { id: "agent", icon: "sparkles" },
  { id: "cli", icon: "terminal" },
  { id: "app", icon: "laptopcomputer.and.iphone" },
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

// On an iPhone or iPad (iPadOS included: a "Mac" with touch), the TestFlight link opens right here, so there's nothing to scan.
function onAppleMobile() {
  return /iPhone|iPad|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
}

/** The prompt for an AI agent: it reads the install skill, then runs cider. */
function agentPrompt(copy: InstallCopy, platform: Sideload) {
  return copy.agent.prompt[platform].replace("{skill}", INSTALL_SKILL).replace("{ipa}", DOWNLOADS[platform]);
}

async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // Older browsers and non-secure contexts: copy through a hidden selection.
    const area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.append(area);
    area.select();
    document.execCommand("copy");
    area.remove();
  }
}

export function Install() {
  const { lang } = useI18n();
  const copy = INSTALL[lang];
  // Starts on the Mac tab, as prerendered, then picks the visitor's tab after hydration.
  const [platform, setPlatform] = useState<Platform>("mac");
  const [mode, setMode] = useState<Mode>("testflight");
  const [onDevice, setOnDevice] = useState(false);
  // Set when a mode is picked: scroll to its content (the prompt for AI agent, else the steps).
  const [jump, setJump] = useState<{ mode: Mode; at: number } | null>(null);
  const [autoCopied, setAutoCopied] = useState(0);
  const promptRef = useRef<HTMLDivElement>(null);
  const howRef = useRef<HTMLDivElement>(null);
  const sideload = platform !== "mac";
  const testflight = sideload && mode === "testflight";

  useEffect(() => {
    setPlatform(initialPlatform());
    setOnDevice(onAppleMobile());
    const onHash = () => {
      const next = hashPlatform();
      if (next) setPlatform(next);
    };
    addEventListener("hashchange", onHash);
    return () => removeEventListener("hashchange", onHash);
  }, []);

  useEffect(() => {
    if (!jump) return;
    // Side by side (wide screens), the steps and the card show together; stacked, jump to the prompt itself.
    const toPrompt = jump.mode === "agent" && !matchMedia("(min-width: 861px)").matches;
    const target = toPrompt ? promptRef.current : howRef.current;
    target?.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: toPrompt ? "center" : "start" });
  }, [jump]);

  const choose = (next: Mode) => {
    if (!sideload) return;
    setMode(next);
    // AI agent is the shortcut: picking it copies the prompt, so the visitor can paste it straight away.
    if (next === "agent") {
      void copyText(agentPrompt(copy, platform));
      setAutoCopied(Date.now());
    }
    setJump({ mode: next, at: Date.now() });
  };

  const steps = !sideload ? copy.steps.mac : mode === "agent" ? copy.agentSteps[platform] : mode === "app" ? copy.appSteps[platform] : copy.steps[platform];

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
              <span className="tab-icon">
                <Icon />
              </span>
              <span>{copy.device[id]}</span>
            </button>
          ))}
        </div>
      </Reveal>

      <div className="install-panel" id="install-panel" role="tabpanel" aria-labelledby={`install-${platform}`}>
        <div className="showcase" key={platform}>
          <p className={sideload && !testflight ? "eyebrow" : "eyebrow signed"}>{testflight ? copy.tf.tag : copy.tag[platform]}</p>
          <h3 className="product">{copy.title[platform]}</h3>
          <p className="product-req">{copy.req[platform]}</p>
          <div className="product-actions">
            {testflight ? (
              <a className="btn-blue" href={TESTFLIGHT[platform]} target="_blank" rel="noreferrer">
                {copy.tf.join}
              </a>
            ) : (
              <a className="btn-blue" href={DOWNLOADS[platform]}>
                {copy.get}
              </a>
            )}
            {platform === "mac" && (
              <a className="link-blue" href={MAC_INTEL_DOWNLOAD}>
                {copy.intel} <SFSymbol name="chevron.right" />
              </a>
            )}
          </div>
          {sideload && (
            <div className="modes-wrap">
              <p className="modes-label" id="install-mode-label">{copy.modes.label}</p>
              <div className="modes" role="radiogroup" aria-labelledby="install-mode-label">
                {MODES.map(({ id, icon }) => (
                  <button key={id} type="button" role="radio" aria-checked={mode === id} className={mode === id ? "mode on" : "mode"} onClick={() => choose(id)}>
                    <SFSymbol name={icon} />
                    <span>{copy.modes[id]}</span>
                    {id === "testflight" && <span className="mode-rec">{copy.modes.rec}</span>}
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>

        <div className={sideload && !testflight ? "how split" : "how"} ref={howRef}>
          <h3 className="how-title">{copy.how}</h3>
          {testflight ? (
            <TestFlightPanel copy={copy} platform={platform} onDevice={onDevice} />
          ) : (
            <>
              {/* Sideloads show the steps on the left and the selected mode's card beside them. */}
              <div className="how-grid">
                <ol className={`steps n${steps.length}`} key={`${platform}-${mode}`}>
                  {steps.map((step, i) => (
                    <li className="step" key={i}>
                      <span className="step-n">{i + 1}</span>
                      <h4>{step.t}</h4>
                      <p>{step.b}</p>
                    </li>
                  ))}
                </ol>

                {sideload && mode === "agent" && (
                  <div className="run single">
                    <div className="run-card" ref={promptRef}>
                      <span className="run-icon"><SFSymbol name="sparkles" /></span>
                      <h3>{copy.agent.t}</h3>
                      <p>{copy.agent.b}</p>
                      <div className="agents">
                        <span className="agents-label">{copy.agent.works}</span>
                        {AGENTS.map((agent) => (
                          <a key={agent.name} className="agent-chip" href={agent.href} target="_blank" rel="noreferrer">
                            {(lang === "ja" || lang === "zh-Hant") && agent.cjk ? agent.cjk : agent.name}
                          </a>
                        ))}
                      </div>
                      <p className="code prompt">{agentPrompt(copy, platform)}</p>
                      <CopyButton text={agentPrompt(copy, platform)} copy={copy} flash={autoCopied} note={copy.copiedPrompt} />
                      <p className="run-note">{copy.agent.web}</p>
                    </div>
                  </div>
                )}
                {sideload && mode === "cli" && <TerminalCard copy={copy} platform={platform} />}
                {sideload && mode === "app" && <AppsCard copy={copy} />}
              </div>
            </>
          )}
        </div>

        {testflight && (
          <div className="keep">
            <h3 className="how-title">{copy.tf.keep.t}</h3>
            <div className="keep-stats">
              <div className="stat">
                <span className="stat-value">{copy.tf.keep.days}</span>
                <span className="stat-label">{copy.tf.keep.daysLabel}</span>
              </div>
              <div className="stat">
                <span className="stat-value">{copy.tf.keep.devices}</span>
                <span className="stat-label">{copy.tf.keep.devicesLabel}</span>
              </div>
            </div>
            <p className="keep-body">{copy.tf.keep.b}</p>
          </div>
        )}
        {sideload && !testflight && (
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
              {copy.guide} <SFSymbol name="chevron.right" />
            </a>
          </div>
        )}
      </div>
    </section>
  );
}

/** The cider commands for a platform, with each comment above its command. */
function commands(copy: InstallCopy, platform: Sideload) {
  const ipa = DOWNLOADS[platform].split("/").pop();
  return [
    [copy.cli.install, "brew tap Muonagi/cider-cli https://github.com/Muonagi/cider-cli", "brew install cider"],
    [copy.cli.login, "cider account login"],
    // cider pairs only over USB; an Apple TV is paired once in Xcode, then cider just finds it.
    platform === "tv" ? [copy.cli.pairTv, "cider device list"] : [copy.cli.pair, "cider device trust"],
    [copy.cli.sign, `cider sign ${ipa} --apple-id --install --refresh`],
  ];
}

function TerminalCard({ copy, platform }: { copy: InstallCopy; platform: Sideload }) {
  const blocks = commands(copy, platform);
  const script = blocks.map(([comment, ...lines]) => [`# ${comment}`, ...lines].join("\n")).join("\n");
  return (
    <div className="run single">
      <div className="run-card">
        <span className="run-icon"><SFSymbol name="terminal" /></span>
        <h3>{copy.cli.t}</h3>
        <p>{copy.cli.b}</p>
        <pre className="code">
          {blocks.map(([comment, ...lines]) => (
            <span key={comment}>
              <span className="cm"># {comment}</span>
              {"\n" + lines.join("\n") + "\n"}
            </span>
          ))}
        </pre>
        <p className="run-note">
          {copy.cli.win}{" "}
          <a href={CIDER} target="_blank" rel="noreferrer">cider</a>
        </p>
        <CopyButton text={script} copy={copy} />
      </div>
    </div>
  );
}

/** TestFlight: the invite's QR code (with the app icon in the middle) beside the steps.
 * On an iPhone or iPad there's nothing to scan, so it shows the steps and the link. */
function TestFlightPanel({ copy, platform, onDevice }: { copy: InstallCopy; platform: Sideload; onDevice: boolean }) {
  const link = TESTFLIGHT[platform];
  return (
    <div className={onDevice ? "tf-panel here" : "tf-panel"} key={platform}>
      {!onDevice && (
        <div className="tf-scan">
          <div className="tf-qr">
            <img className="tf-code" src={`/testflight/${platform}.svg`} alt={link} width={232} height={232} />
            <img className="tf-logo" src="/assets/icon-192.png" alt="" width={52} height={52} />
          </div>
          <p className="tf-scan-title">
            <SFSymbol name="qrcode" />
            {copy.tf.t}
          </p>
          <p className="tf-url">{link.replace("https://", "")}</p>
        </div>
      )}
      <div className="tf-side">
        <ol className="tf-steps">
          {copy.tf.steps[platform].map((step, i) => (
            <li key={i}>
              <span className="step-n">{i + 1}</span>
              <h4>{step.t}</h4>
              <p>{step.b}</p>
            </li>
          ))}
        </ol>
        {onDevice && <p className="tf-here">{copy.tf.here[platform]}</p>}
        <div className="tf-actions">
          <a className="btn-blue" href={link} target="_blank" rel="noreferrer">
            {copy.tf.open}
          </a>
          <a className="link-blue" href={TESTFLIGHT_APP} target="_blank" rel="noreferrer">
            {copy.tf.app} <SFSymbol name="chevron.right" />
          </a>
        </div>
      </div>
    </div>
  );
}

function AppsCard({ copy }: { copy: InstallCopy }) {
  const apps = [
    { name: "Impactor", href: IMPACTOR, note: copy.apps.impactor },
    { name: "iloader", href: ILOADER, note: copy.apps.iloader },
    { name: "Sideloadly", href: SIDELOADLY, note: copy.apps.sideloadly },
  ];
  return (
    <div className="run single">
      <div className="run-card">
        <span className="run-icon"><SFSymbol name="laptopcomputer.and.iphone" /></span>
        <h3>{copy.apps.t}</h3>
        <p>{copy.apps.b}</p>
        <ul className="apps">
          {apps.map((app) => (
            <li key={app.name}>
              <a href={app.href} target="_blank" rel="noreferrer">
                {app.name} <SFSymbol name="chevron.right" />
              </a>
              <span>{app.note}</span>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

/** Copies on click; `flash` (a timestamp) shows the copied state when something else copied the same text. */
function CopyButton({ text, copy, flash = 0, note }: { text: string; copy: InstallCopy; flash?: number; note?: string }) {
  const [doneAt, setDoneAt] = useState(0);
  useEffect(() => {
    if (flash) setDoneAt(flash);
  }, [flash]);
  useEffect(() => {
    if (!doneAt) return;
    const timer = setTimeout(() => setDoneAt(0), 2500);
    return () => clearTimeout(timer);
  }, [doneAt]);
  const done = doneAt > 0;
  return (
    <div className="copy-row">
      <button
        type="button"
        className={done ? "copy-btn done" : "copy-btn"}
        onClick={async () => {
          await copyText(text);
          setDoneAt(Date.now());
        }}
      >
        <SFSymbol name={done ? "checkmark" : "doc.on.doc"} />
        <span>{done ? copy.copied : copy.copy}</span>
      </button>
      <span className="copy-note" aria-live="polite">
        {done && note ? note : ""}
      </span>
    </div>
  );
}
