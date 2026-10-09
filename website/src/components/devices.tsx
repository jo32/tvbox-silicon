// Product-style device renders for the install section. Each screen shows a real app screenshot.

interface Props {
  /** Screenshot URL shown on the device's screen(s). */
  shot: string;
}

const Aluminum = ({ id, light = "#e9e9ec", dark = "#b5b6bb" }: { id: string; light?: string; dark?: string }) => (
  <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stopColor={light} />
    <stop offset="1" stopColor={dark} />
  </linearGradient>
);

/** A screenshot clipped to a rounded screen. */
function Screen({ id, shot, x, y, w, h, r }: { id: string; shot: string; x: number; y: number; w: number; h: number; r: number }) {
  return (
    <>
      <clipPath id={id}>
        <rect x={x} y={y} width={w} height={h} rx={r} />
      </clipPath>
      <rect x={x} y={y} width={w} height={h} rx={r} fill="#111" />
      <image href={shot} x={x} y={y} width={w} height={h} preserveAspectRatio="xMidYMid slice" clipPath={`url(#${id})`} />
      {/* Glass sheen */}
      <rect x={x} y={y} width={w} height={h} rx={r} fill="url(#dev-sheen)" />
    </>
  );
}

const Sheen = () => (
  <linearGradient id="dev-sheen" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stopColor="#fff" stopOpacity="0.10" />
    <stop offset="0.45" stopColor="#fff" stopOpacity="0" />
  </linearGradient>
);

const Shadow = ({ cx, cy, rx, ry }: { cx: number; cy: number; rx: number; ry: number }) => (
  <>
    <radialGradient id="dev-shadow">
      <stop offset="0" stopColor="#000" stopOpacity="0.22" />
      <stop offset="1" stopColor="#000" stopOpacity="0" />
    </radialGradient>
    <ellipse cx={cx} cy={cy} rx={rx} ry={ry} fill="url(#dev-shadow)" />
  </>
);

export function MacBookArt({ shot }: Props) {
  return (
    <svg viewBox="0 0 800 470" role="img" aria-label="MacBook">
      <defs>
        <Aluminum id="mb-lid" light="#d9dade" dark="#bcbdc2" />
        <Aluminum id="mb-base" light="#ececef" dark="#a9aab0" />
        <Sheen />
      </defs>
      <Shadow cx={400} cy={452} rx={380} ry={14} />
      <rect x="104" y="4" width="592" height="390" rx="26" fill="url(#mb-lid)" />
      <rect x="108" y="8" width="584" height="382" rx="23" fill="#0b0b0d" />
      <Screen id="mb-screen" shot={shot} x={122} y={22} w={556} h={350} r={8} />
      <rect x="378" y="22" width="44" height="11" rx="5.5" fill="#0b0b0d" />
      <path d="M36 394h728v8c0 14-9 24-24 28-80 14-210 18-340 18s-260-4-340-18c-15-4-24-14-24-28z" fill="url(#mb-base)" />
      <rect x="36" y="392" width="728" height="6" rx="3" fill="#dfe0e4" />
      <path d="M340 394h120v3a6 6 0 0 1-6 6H346a6 6 0 0 1-6-6z" fill="#a3a4aa" />
    </svg>
  );
}

export function IPhoneIPadArt({ shot }: Props) {
  return (
    <svg viewBox="0 0 800 470" role="img" aria-label="iPad and iPhone">
      <defs>
        <Aluminum id="ipad-frame" light="#e2e3e7" dark="#b9bac0" />
        <Aluminum id="iphone-frame" light="#5b5b60" dark="#2e2e32" />
        <Sheen />
      </defs>
      <Shadow cx={400} cy={455} rx={360} ry={12} />
      {/* iPad, landscape */}
      <rect x="40" y="34" width="580" height="410" rx="36" fill="url(#ipad-frame)" />
      <rect x="45" y="39" width="570" height="400" rx="32" fill="#0a0a0c" />
      <Screen id="ipad-screen" shot={shot} x={64} y={58} w={532} h={362} r={16} />
      {/* iPhone */}
      <rect x="560" y="128" width="184" height="330" rx="40" fill="url(#iphone-frame)" />
      <rect x="564" y="132" width="176" height="322" rx="37" fill="#050506" />
      <Screen id="iphone-screen" shot={shot} x={572} y={140} w={160} h={306} r={30} />
      <rect x="630" y="150" width="44" height="13" rx="6.5" fill="#050506" />
    </svg>
  );
}

export function AppleTVArt({ shot }: Props) {
  return (
    <svg viewBox="0 0 800 470" role="img" aria-label="Apple TV and Siri Remote">
      <defs>
        <Aluminum id="tv-stand" light="#d6d7db" dark="#9fa0a6" />
        <Aluminum id="remote" light="#f3f3f5" dark="#c4c5cb" />
        <linearGradient id="atv-box" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#3c3c41" />
          <stop offset="0.22" stopColor="#18181b" />
          <stop offset="1" stopColor="#0a0a0b" />
        </linearGradient>
        <Sheen />
      </defs>
      <Shadow cx={400} cy={456} rx={370} ry={12} />
      {/* TV */}
      <rect x="60" y="6" width="620" height="358" rx="10" fill="#0b0b0c" />
      <Screen id="tv-screen" shot={shot} x={67} y={13} w={606} h={341} r={3} />
      <path d="M340 364h60l10 66h-80z" fill="url(#tv-stand)" />
      <rect x="270" y="428" width="200" height="10" rx="5" fill="url(#tv-stand)" />
      {/* Apple TV */}
      <rect x="86" y="396" width="160" height="52" rx="16" fill="url(#atv-box)" />
      <rect x="96" y="399" width="140" height="3" rx="1.5" fill="#fff" opacity="0.14" />
      {/* Siri Remote */}
      <rect x="704" y="296" width="36" height="156" rx="15" fill="url(#remote)" stroke="#b3b4ba" strokeWidth="1" />
      <circle cx="722" cy="324" r="13.5" fill="#e4e4e8" stroke="#b8b9bf" strokeWidth="0.8" />
      <circle cx="722" cy="324" r="7" fill="#efeff2" stroke="#c6c7cc" strokeWidth="0.6" />
      <circle cx="714" cy="351" r="4.5" fill="#1d1d20" />
      <circle cx="730" cy="351" r="4.5" fill="#1d1d20" />
      <circle cx="714" cy="364" r="4.5" fill="#1d1d20" />
      <rect x="725.5" y="359.5" width="9" height="26" rx="4.5" fill="#1d1d20" />
      <circle cx="714" cy="377" r="4.5" fill="#1d1d20" />
    </svg>
  );
}

// Small line icons for the tab bar.
export const MacIcon = () => (
  <svg viewBox="0 0 36 36" aria-hidden="true"><rect x="7" y="8" width="22" height="15" rx="1.8" /><path d="M3.5 26.5h29" /></svg>
);
export const DevicesIcon = () => (
  <svg viewBox="0 0 36 36" aria-hidden="true"><rect x="4" y="7" width="21" height="16" rx="2.4" /><rect x="22" y="13" width="10" height="17" rx="2.4" /></svg>
);
export const TVIcon = () => (
  <svg viewBox="0 0 36 36" aria-hidden="true"><rect x="4" y="7" width="28" height="17" rx="1.6" /><path d="M14 29h8M18 24v5" /></svg>
);
