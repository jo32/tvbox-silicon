// Renders the social preview images public/og/<lang>.jpg (1200x675): the first feature card's Apple TV
// mockup screen, in each page language. Rerun after changing the mockups:
//   npm run build:site && npx vite preview --port 4199   (in another terminal)
//   node scripts/og-images.mjs [http://localhost:4199]
// Needs Google Chrome; it drives headless Chrome over the DevTools protocol.
import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BASE = process.argv[2] ?? "http://localhost:4199";
const PAGES = { en: "/", ja: "/ja/", ko: "/ko/", "zh-Hant": "/zh-hant/" };
const WIDTH = 1200;
const HEIGHT = 675;
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const OUT = new URL("../public/og/", import.meta.url).pathname;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

mkdirSync(OUT, { recursive: true });
const port = 9300 + Math.floor(Math.random() * 600);
const dir = mkdtempSync(join(tmpdir(), "og-"));
const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${dir}`, "--no-first-run", "--hide-scrollbars", "about:blank"], { stdio: "ignore" });
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
  for (const [lang, path] of Object.entries(PAGES)) {
    // A saved language would redirect the page, so start each one clean.
    await send("Page.navigate", { url: `${BASE}${path}` });
    await sleep(2500);
    const box = await evaluate(`(async () => {
      localStorage.clear();
      document.querySelectorAll('.reveal').forEach((e) => e.classList.add('in'));
      await new Promise((r) => setTimeout(r, 900));
      document.querySelectorAll('img').forEach((i) => (i.loading = 'eager'));
      await Promise.all([...document.images].map((i) => i.decode().catch(() => 0)));
      await document.fonts.ready;
      const r = document.querySelector('.card .screen').getBoundingClientRect();
      return { x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height, lang: document.documentElement.lang };
    })()`);
    if (box.lang !== lang) throw new Error(`${path} rendered in ${box.lang}, not ${lang}`);
    await sleep(500);
    const { result } = await send("Page.captureScreenshot", { format: "jpeg", quality: 85, captureBeyondViewport: true, clip: { x: box.x, y: box.y, width: Math.floor(box.w), height: Math.ceil((HEIGHT * Math.floor(box.w)) / WIDTH), scale: WIDTH / Math.floor(box.w) } });
    // Chrome clips whole CSS pixels, so the capture can be a pixel taller; crop it to the exact size.
    const file = join(OUT, `${lang}.jpg`);
    writeFileSync(file, Buffer.from(result.data, "base64"));
    execFileSync("sips", ["-c", String(HEIGHT), String(WIDTH), file], { stdio: "ignore" });
    console.log(`public/og/${lang}.jpg`);
  }
  ws.close();
} finally {
  chrome.kill("SIGKILL");
  rmSync(dir, { recursive: true, force: true });
}
