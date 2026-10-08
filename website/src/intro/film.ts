// Intro film: every scene's CSS animations are paused and driven from one clock, so the
// seek bar can scrub the whole film. Scene times come from data-s/data-e (seconds).
// The film renders in a shadow root so its styles and the host page's never touch.
import type { Lang } from "../i18n/strings";
import css from "./film.css?inline";
import markup from "./film.html?raw";
import { translateFilm, tr } from "./film-i18n";

const TOTAL = 100;
const FADE = 0.45;
const PRESS = 0.28;

// Siri Remote presses, in film seconds, so the remote beside the TV mirrors what happens on screen.
const PRESSES: [number, string][] = [
  [0.3, "power"],
  [20.4, "select"], [23.2, "select"],
  [46.6, "right"], [48.3, "right"], [52, "select"],
  [65, "play"], [71.8, "select"],
  [77, "down"], [78, "down"],
];

export interface FilmOptions {
  lang: Lang;
  /** Second to open at, paused. */
  startAt?: number;
  /** Space and arrow keys control the film (standalone page only). */
  keys?: boolean;
}

const easeOut = (x: number) => 1 - (1 - x) ** 3;
const clock = (t: number) => {
  const s = Math.floor(t);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

/** Renders the film into `host` and starts it. Returns a function that stops it. */
export function mountFilm(host: HTMLElement, { lang, startAt, keys = false }: FilmOptions): () => void {
  const shadow = host.shadowRoot ?? host.attachShadow({ mode: "open" });
  shadow.innerHTML = `<style>${css}</style>${markup}`;
  const root = shadow.querySelector<HTMLElement>(".film")!;
  root.lang = lang;
  translateFilm(root, lang);
  // Same screenshot folders as the site: Korean uses the English app UI.
  const shots = lang === "ja" || lang === "zh-Hant" ? lang : "en";
  for (const img of root.querySelectorAll<HTMLImageElement>('img[src^="/screenshots/en/"]')) {
    img.src = img.getAttribute("src")!.replace("/en/", `/${shots}/`);
  }

  const scenes = Array.from(root.querySelectorAll<HTMLElement>(".scene"));
  const pp = root.querySelector<HTMLButtonElement>("#pp")!;
  const seek = root.querySelector<HTMLInputElement>("#seek")!;
  const out = root.querySelector<HTMLOutputElement>("#clock")!;
  const chap = root.querySelector<HTMLElement>("#chap")!;
  const led = root.querySelector<HTMLElement>("#led")!;
  const remoteKeys = Array.from(root.querySelectorAll<HTMLElement>(".remote [data-k]"));

  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  let t = reduced ? 2 : 0;
  let playing = !reduced;
  if (startAt !== undefined) { t = Math.min(TOTAL - 0.01, Math.max(0, startAt)); playing = false; }
  let last: number | null = null;
  let visible = true;
  let raf = 0;

  const label = () => { pp.textContent = tr(lang, playing ? "Pause" : t >= TOTAL - 0.05 ? "Replay" : "Play"); };

  function render() {
    let chapter = "";
    for (const el of scenes) {
      const s = Number(el.dataset.s), e = Number(el.dataset.e);
      const on = t >= s && t < e;
      el.style.visibility = on ? "visible" : "hidden";
      if (!on) { el.style.opacity = "0"; continue; }
      chapter = el.dataset.ch ?? "";
      el.style.opacity = String(Math.max(0, Math.min((t - s) / FADE, (e - t) / FADE, 1)));
      const local = t - s;
      for (const a of el.getAnimations({ subtree: true })) { a.pause(); a.currentTime = local * 1000; }
      el.querySelectorAll<HTMLElement>(".cnt").forEach((c) => {
        const p = Math.max(0, Math.min(1, (local - Number(c.dataset.d)) / Number(c.dataset.dur)));
        c.textContent = String(Math.round(Number(c.dataset.to) * easeOut(p)));
      });
    }
    chap.querySelector("span")!.textContent = chapter;
    chap.classList.toggle("on", chapter !== "");

    const down = new Set(PRESSES.filter(([at]) => t >= at && t < at + PRESS).map(([, k]) => k));
    for (const k of remoteKeys) k.classList.toggle("on", down.has(k.dataset.k!));
    led.classList.toggle("on", down.size > 0);

    seek.value = String(t);
    out.textContent = `${clock(t)} / ${clock(TOTAL)}`;
  }

  // Offscreen, the clock stops and nothing renders.
  function frame(now: number) {
    if (visible) {
      if (playing && last !== null) t += Math.min((now - last) / 1000, 0.1);
      if (t >= TOTAL) { t = TOTAL - 0.01; playing = false; label(); }
      last = now;
      render();
    } else {
      last = null;
    }
    raf = requestAnimationFrame(frame);
  }

  const toggle = () => {
    if (!playing && t >= TOTAL - 0.05) t = 0;
    playing = !playing;
    label();
  };
  const onSeek = () => { t = Number(seek.value); render(); };
  const onKey = (e: KeyboardEvent) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLButtonElement || e.target instanceof HTMLSelectElement) return;
    if (e.key === " ") { e.preventDefault(); toggle(); }
    else if (e.key === "ArrowRight") t = Math.min(TOTAL - 0.01, t + 5);
    else if (e.key === "ArrowLeft") t = Math.max(0, t - 5);
  };
  pp.addEventListener("click", toggle);
  seek.addEventListener("input", onSeek);
  if (keys) addEventListener("keydown", onKey);
  const io = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; });
  io.observe(host);

  label();
  render();
  raf = requestAnimationFrame(frame);

  return () => {
    cancelAnimationFrame(raf);
    io.disconnect();
    if (keys) removeEventListener("keydown", onKey);
    pp.removeEventListener("click", toggle);
    seek.removeEventListener("input", onSeek);
  };
}
