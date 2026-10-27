// Mac, iPad and iPhone screens for the device mockups (see Device.tsx), laid out like the app's Watch Now.
import { SFSymbol } from "./SFSymbol";
import { useMockText } from "./mock-i18n";
import { CategoryChips, Poster, SourceChips, titles } from "./mock-parts";

const SIDEBAR: [string, [string, string][]][] = [
  [
    "Browse",
    [
      ["play.rectangle", "Watch Now"],
      ["magnifyingglass", "Global Search"],
      ["antenna.radiowaves.left.and.right", "Live TV"],
      ["square.grid.2x2", "Sources"],
    ],
  ],
  [
    "Library",
    [
      ["heart", "Favorites"],
      ["arrow.down.circle", "Downloads"],
      ["gearshape", "Settings"],
    ],
  ],
];

export function MacWatchNow() {
  const m = useMockText();
  return (
    <div className="mac">
      <aside className="mac-side">
        <div className="lights">
          <i />
          <i />
          <i />
        </div>
        {SIDEBAR.map(([head, items]) => (
          <div key={head}>
            <p className="mac-head">{m(head)}</p>
            {items.map(([icon, label]) => (
              <p key={label} className={label === "Watch Now" ? "mac-item on" : "mac-item"}>
                <SFSymbol name={icon} />
                {m(label)}
              </p>
            ))}
          </div>
        ))}
        <p className="mac-ver">{m("Version 1.8.1")}</p>
      </aside>
      <div className="mac-main">
        <p className="mac-title">{m("Watch Now")}</p>
        <div className="m-tools">
          <SourceChips />
          <span className="m-round">
            <SFSymbol name="arrow.clockwise" />
          </span>
        </div>
        <CategoryChips />
        <div className="m-grid mac-grid">
          {titles(0, 18).map((t) => (
            <Poster key={t.img} title={t} />
          ))}
        </div>
      </div>
    </div>
  );
}

function Status({ phone = false }: { phone?: boolean }) {
  return (
    <div className="m-status">
      <b>9:41</b>
      <span className="end">
        {phone && <SFSymbol name="cellularbars" />}
        <SFSymbol name="wifi" />
        <SFSymbol name="battery.100percent" />
      </span>
    </div>
  );
}

export function IPadWatchNow() {
  const m = useMockText();
  return (
    <div className="ipad">
      <Status />
      <div className="ipad-tabs">
        <span className="tb tb-icon">
          <SFSymbol name="sidebar.left" />
        </span>
        {["Watch Now", "Live TV", "Global Search", "Sources"].map((label, i) => (
          <span key={label} className={i === 0 ? "tb on" : "tb"}>
            {m(label)}
          </span>
        ))}
      </div>
      <div className="m-tools">
        <SourceChips />
        <span className="m-round">
          <SFSymbol name="arrow.clockwise" />
        </span>
      </div>
      <CategoryChips />
      <div className="m-grid ipad-grid">
        {titles(4, 30).map((t, i) => (
          <Poster key={i} title={t} />
        ))}
      </div>
    </div>
  );
}

const PHONE_TABS: [string, string][] = [
  ["play.rectangle", "Watch Now"],
  ["antenna.radiowaves.left.and.right", "Live TV"],
  ["magnifyingglass", "Global Search"],
  ["square.grid.2x2", "Sources"],
  ["ellipsis", "More"],
];

export function IPhoneWatchNow() {
  const m = useMockText();
  return (
    <div className="iphone">
      <Status phone />
      <p className="ph-title">{m("Watch Now")}</p>
      <SourceChips />
      <CategoryChips />
      <div className="m-grid ph-grid">
        {titles(10, 12).map((t) => (
          <Poster key={t.img} title={t} />
        ))}
      </div>
      <nav className="ph-tabs">
        {PHONE_TABS.map(([icon, label], i) => (
          <span key={label} className={i === 0 ? "ph-tab on" : "ph-tab"}>
            <SFSymbol name={icon} />
            {m(label)}
          </span>
        ))}
      </nav>
    </div>
  );
}
