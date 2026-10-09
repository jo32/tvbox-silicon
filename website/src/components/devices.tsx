// Device illustrations for the install picker: a MacBook, an iPad with an iPhone, and an Apple TV
// with its Siri Remote in front of a TV. Each screen shows a tiny poster grid like the app.

const POSTERS = ["#ff9f6e", "#7d8cff", "#5ad1c4", "#ff7a9a", "#ffd36e", "#9b7dff"];

/** A row of poster tiles inside a screen rectangle. */
function Posters({ x, y, w, h, n = 4 }: { x: number; y: number; w: number; h: number; n?: number }) {
  const gap = w * 0.04;
  const pw = (w - gap * (n - 1)) / n;
  return (
    <g>
      {Array.from({ length: n }, (_, i) => (
        <rect key={i} x={x + i * (pw + gap)} y={y} width={pw} height={h} rx={Math.min(3, pw / 6)} fill={POSTERS[i % POSTERS.length]} />
      ))}
    </g>
  );
}

function Wallpaper({ id }: { id: string }) {
  return (
    <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stopColor="#1d2464" />
      <stop offset="0.6" stopColor="#2a3c9a" />
      <stop offset="1" stopColor="#3a7fb8" />
    </linearGradient>
  );
}

export function MacBookArt() {
  return (
    <svg viewBox="0 0 240 150" aria-hidden="true">
      <defs>
        <Wallpaper id="art-mac-wall" />
        <linearGradient id="art-mac-base" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#ececf0" />
          <stop offset="1" stopColor="#b4b4bc" />
        </linearGradient>
      </defs>
      <rect x="40" y="14" width="160" height="106" rx="9" fill="#1a1a1d" />
      <rect x="45" y="19" width="150" height="96" rx="3" fill="url(#art-mac-wall)" />
      <rect x="112" y="19" width="16" height="4.5" rx="2" fill="#1a1a1d" />
      {/* App window */}
      <rect x="58" y="32" width="124" height="72" rx="5" fill="#121214" />
      <circle cx="64" cy="37" r="1.6" fill="#ff5f57" />
      <circle cx="69" cy="37" r="1.6" fill="#febc2e" />
      <circle cx="74" cy="37" r="1.6" fill="#28c840" />
      <rect x="64" y="44" width="30" height="4" rx="2" fill="#f39a5b" />
      <Posters x={64} y={53} w={112} h={22} n={5} />
      <Posters x={64} y={79} w={112} h={20} n={5} />
      <path d="M14 121h212l-7 8.5a7 7 0 0 1-5.4 2.5H26.4a7 7 0 0 1-5.4-2.5z" fill="url(#art-mac-base)" />
      <rect x="14" y="119" width="212" height="4" rx="2" fill="#dcdce2" />
      <rect x="102" y="119" width="36" height="3" rx="1.5" fill="#a7a7af" />
    </svg>
  );
}

export function IPhoneIPadArt() {
  return (
    <svg viewBox="0 0 240 150" aria-hidden="true">
      <defs>
        <Wallpaper id="art-ios-wall" />
      </defs>
      {/* iPad, landscape */}
      <rect x="22" y="16" width="156" height="114" rx="12" fill="#1a1a1d" />
      <rect x="29" y="23" width="142" height="100" rx="6" fill="url(#art-ios-wall)" />
      <rect x="38" y="32" width="34" height="5" rx="2.5" fill="#f39a5b" />
      <Posters x={38} y={44} w={124} h={34} n={5} />
      <Posters x={38} y={84} w={124} h={30} n={5} />
      {/* iPhone in front */}
      <rect x="156" y="36" width="60" height="110" rx="13" fill="#2a2a2e" />
      <rect x="158.5" y="38.5" width="55" height="105" rx="11" fill="#0e0e10" />
      <rect x="161.5" y="41.5" width="49" height="99" rx="9" fill="url(#art-ios-wall)" />
      <rect x="177" y="45" width="18" height="5.5" rx="2.75" fill="#0e0e10" />
      <rect x="166" y="56" width="20" height="4" rx="2" fill="#f39a5b" />
      <Posters x={166} y={64} w={40} h={26} n={2} />
      <Posters x={166} y={95} w={40} h={26} n={2} />
      <rect x="175" y="133" width="22" height="2" rx="1" fill="#ffffff" opacity="0.7" />
    </svg>
  );
}

export function AppleTVArt() {
  return (
    <svg viewBox="0 0 240 150" aria-hidden="true">
      <defs>
        <Wallpaper id="art-tv-wall" />
        <linearGradient id="art-tv-box" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#3a3a3f" />
          <stop offset="0.18" stopColor="#1b1b1e" />
          <stop offset="1" stopColor="#0c0c0e" />
        </linearGradient>
        <linearGradient id="art-tv-remote" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#c9c9cf" />
          <stop offset="0.5" stopColor="#f1f1f4" />
          <stop offset="1" stopColor="#bdbdc4" />
        </linearGradient>
      </defs>
      {/* TV */}
      <rect x="20" y="8" width="176" height="102" rx="5" fill="#111113" />
      <rect x="24" y="12" width="168" height="94" rx="2" fill="url(#art-tv-wall)" />
      <rect x="34" y="20" width="40" height="5" rx="2.5" fill="#f39a5b" />
      <Posters x={34} y={32} w={148} h={34} n={5} />
      <Posters x={34} y={72} w={148} h={26} n={5} />
      <rect x="98" y="110" width="20" height="8" fill="#2b2b30" />
      <rect x="76" y="117" width="64" height="4" rx="2" fill="#3a3a40" />
      {/* Apple TV box */}
      <rect x="40" y="122" width="84" height="22" rx="7" fill="url(#art-tv-box)" />
      <rect x="44" y="124" width="76" height="2" rx="1" fill="#ffffff" opacity="0.12" />
      {/* Siri Remote */}
      <rect x="196" y="56" width="26" height="90" rx="9" fill="url(#art-tv-remote)" stroke="#a9a9b1" strokeWidth="0.8" />
      <circle cx="209" cy="72" r="10" fill="#dedee3" stroke="#b4b4bb" strokeWidth="0.8" />
      <circle cx="209" cy="72" r="5.2" fill="#ececf0" stroke="#c2c2c8" strokeWidth="0.6" />
      <circle cx="203.5" cy="91" r="3.2" fill="#2a2a2e" />
      <circle cx="214.5" cy="91" r="3.2" fill="#2a2a2e" />
      <circle cx="203.5" cy="100" r="3.2" fill="#2a2a2e" />
      <rect x="211.3" y="95" width="6.4" height="17" rx="3.2" fill="#2a2a2e" />
      <circle cx="203.5" cy="109" r="3.2" fill="#2a2a2e" />
    </svg>
  );
}
