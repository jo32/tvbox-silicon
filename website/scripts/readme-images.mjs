// Renders the README's pictures, Docs/images/*.webp (transparent around the device): the website's HTML device mockups, never app screenshots (the
// app's look changes too often). Rerun after changing the mockups and deploying, or against a local preview:
//   node scripts/readme-images.mjs [https://yingxia.getmegaportal.com]
// Needs Google Chrome; it drives headless Chrome over the DevTools protocol.
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BASE = process.argv[2] ?? "https://yingxia.getmegaportal.com";
const OUT = new URL("../../Docs/images/", import.meta.url).pathname;
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const SCALE = 2;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// [file, install tab to open first (or null), selector, index]
const SHOTS = [
  // apple-tv.webp, mac.webp and iphone-ipad.webp came from the install section's device mockups, which the site
  // no longer shows (2026-11-24); the files in Docs/images stay as they are.
  ["live.webp", null, ".card .device", 0],
  ["search.webp", null, ".card .device", 1],
  ["source.webp", null, ".card .device", 2],
];

mkdirSync(OUT, { recursive: true });
const port = 9300 + Math.floor(Math.random() * 600);
const dir = mkdtempSync(join(tmpdir(), "readme-"));
const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${dir}`, "--lang=en-US", "--accept-lang=en-US", "--no-first-run", "--hide-scrollbars", "about:blank"], { stdio: "ignore" });
try {
  let page;
  for (let i = 0; i < 75 && !page; i++) {
    try {
      page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page");
    } catch {}
    if (!page) await sleep(200);
  }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0;
  const pending = new Map();
  ws.onmessage = ({ data }) => {
    const m = JSON.parse(data);
    if (m.id) pending.get(m.id)?.(m);
  };
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result.result?.value;
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  // GitHub shows the README on light and dark pages, so only the device itself may be opaque.
  await send("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
  await send("Page.navigate", { url: `${BASE}/` });
  await sleep(3000);
  for (const [file, tab, selector, index] of SHOTS) {
    const box = await evaluate(`(async () => {
      ${tab ? `document.getElementById('install-${tab}').click();` : ""}
      await new Promise((r) => setTimeout(r, 900));
      document.querySelectorAll('.reveal').forEach((e) => e.classList.add('in'));
      document.querySelectorAll('img').forEach((i) => (i.loading = 'eager'));
      await Promise.all([...document.images].map((i) => i.decode().catch(() => 0)));
      await document.fonts.ready;
      document.querySelectorAll('*').forEach((e) => { if (!e.closest('.screen')) { e.style.background = 'transparent'; e.style.boxShadow = 'none'; } });
      await new Promise((r) => setTimeout(r, 900));
      const r = document.querySelectorAll(${JSON.stringify(selector)})[${index}].getBoundingClientRect();
      return { x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height, lang: document.documentElement.lang };
    })()`);
    if (box.lang !== "en") throw new Error(`page rendered in ${box.lang}, not en`);
    const { result } = await send("Page.captureScreenshot", { format: "webp", quality: 85, captureBeyondViewport: true, clip: { x: box.x, y: box.y, width: box.w, height: box.h, scale: SCALE } });
    writeFileSync(join(OUT, file), Buffer.from(result.data, "base64"));
    console.log(`Docs/images/${file} ${Math.round(box.w * SCALE)}x${Math.round(box.h * SCALE)}`);
  }
  ws.close();
} finally {
  chrome.kill("SIGKILL");
  rmSync(dir, { recursive: true, force: true });
}
