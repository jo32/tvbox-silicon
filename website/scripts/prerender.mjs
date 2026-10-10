// Runs after `vite build`: renders the homepage into dist/ once per language (/, /ja/, /ko/,
// /zh-hant/) with its own title, canonical URL, hreflang links, Open Graph tags and JSON-LD, so
// search engines and AI crawlers that don't run JavaScript still see the page. Also writes
// sitemap.xml and llms.txt from the same copy, so they follow edits to the strings and downloads.
import react from "@vitejs/plugin-react";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { build } from "vite";

const root = resolve(import.meta.dirname, "..");
const dist = join(root, "dist");
const ssrOut = join(root, "node_modules/.prerender");

await build({
  root,
  configFile: false,
  logLevel: "warn",
  plugins: [react()],
  build: {
    ssr: "src/entry-server.tsx",
    outDir: ssrOut,
    emptyOutDir: true,
    rollupOptions: { output: { entryFileNames: "entry-server.js" } },
  },
});

const { render, LANGS, LOCALES, LANG_PATH, SITE_URL, INSTALL, DOWNLOADS, MAC_DOWNLOAD, INSTALL_GUIDE, REPO } = await import(
  pathToFileURL(join(ssrOut, "entry-server.js")).href
);

const OG_LOCALE = { en: "en_US", ja: "ja_JP", ko: "ko_KR", "zh-Hant": "zh_TW" };
const LANG_NAME_EN = { en: "English", ja: "Japanese", ko: "Korean", "zh-Hant": "Traditional Chinese" };
const VERSION = /\/(\d+(?:\.\d+)+)\//.exec(MAC_DOWNLOAD)?.[1];
const FAQ = [1, 2, 3, 4, 5, 6];

const escape = (s) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const jsonLd = (value) => `<script type="application/ld+json">${JSON.stringify(value).replace(/</g, "\\u003c")}</script>`;
const pageUrl = (lang) => SITE_URL + LANG_PATH[lang];

// [hreflang, page language]. The only Chinese page is Traditional, so it also serves plain "zh".
const ALTERNATES = [...LANGS.map((lang) => [lang, lang]), ["zh", "zh-Hant"], ["x-default", "en"]];

function head(lang) {
  const { text: t, shots } = LOCALES[lang];
  const url = pageUrl(lang);
  const image = `${SITE_URL}/screenshots/${shots}/home.jpg`;
  const app = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Yingxia",
    alternateName: "映匣",
    description: t["meta.description"],
    url,
    image,
    inLanguage: lang,
    applicationCategory: "MultimediaApplication",
    operatingSystem: "macOS 26, iOS 26, iPadOS 26, tvOS 26",
    softwareVersion: VERSION,
    downloadUrl: MAC_DOWNLOAD,
    installUrl: `${url}#install`,
    isAccessibleForFree: true,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    license: "https://www.gnu.org/licenses/gpl-3.0.html",
    sameAs: [REPO],
  };
  const faq = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    inLanguage: lang,
    mainEntity: FAQ.map((n) => ({
      "@type": "Question",
      name: t[`q${n}.q`],
      acceptedAnswer: { "@type": "Answer", text: t[`q${n}.a`] },
    })),
  };
  return [
    `<title>${escape(t["meta.title"])}</title>`,
    `<meta name="description" content="${escape(t["meta.description"])}" />`,
    `<link rel="canonical" href="${url}" />`,
    ...ALTERNATES.map(([hreflang, l]) => `<link rel="alternate" hreflang="${hreflang}" href="${pageUrl(l)}" />`),
    `<meta property="og:type" content="website" />`,
    `<meta property="og:site_name" content="Yingxia · 映匣" />`,
    `<meta property="og:url" content="${url}" />`,
    `<meta property="og:title" content="${escape(t["meta.title"])}" />`,
    `<meta property="og:description" content="${escape(t["meta.description"])}" />`,
    `<meta property="og:image" content="${image}" />`,
    `<meta property="og:image:width" content="1920" />`,
    `<meta property="og:image:height" content="1080" />`,
    `<meta property="og:image:alt" content="${escape(t["meta.title"])}" />`,
    `<meta property="og:locale" content="${OG_LOCALE[lang]}" />`,
    ...LANGS.filter((l) => l !== lang).map((l) => `<meta property="og:locale:alternate" content="${OG_LOCALE[l]}" />`),
    `<meta name="twitter:card" content="summary_large_image" />`,
    jsonLd(app),
    jsonLd(faq),
  ].join("\n    ");
}

const SEO_BLOCK = /<!-- seo:[\s\S]*?<!-- \/seo -->/;
const EMPTY_ROOT = '<div id="root"></div>';
const template = await readFile(join(dist, "index.html"), "utf8");
if (!SEO_BLOCK.test(template) || !template.includes(EMPTY_ROOT) || !template.includes('<html lang="en">')) {
  throw new Error("dist/index.html lacks the seo block, the empty #root or <html lang> (already prerendered? run vite build first)");
}

for (const lang of LANGS) {
  const html = template
    .replace('<html lang="en">', `<html lang="${lang}">`)
    .replace(SEO_BLOCK, () => head(lang))
    .replace(EMPTY_ROOT, () => `<div id="root" data-lang="${lang}">${render(lang)}</div>`);
  const file = join(dist, LANG_PATH[lang], "index.html");
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, html);
}

const links = ALTERNATES.map(([hreflang, l]) => `<xhtml:link rel="alternate" hreflang="${hreflang}" href="${pageUrl(l)}"/>`).join("");
const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${LANGS.map((lang) => `  <url><loc>${pageUrl(lang)}</loc>${links}</url>`).join("\n")}
  <url><loc>${SITE_URL}/intro/</loc></url>
</urlset>
`;
await writeFile(join(dist, "sitemap.xml"), sitemap);

// llms.txt (https://llmstxt.org): a plain summary for coding agents and AI tools, in English.
const en = LOCALES.en.text;
const install = INSTALL.en;
const llms = `# Yingxia (映匣)

> ${en["meta.description"]}

${en["hero.sub"]}

${install.sub}

${FAQ.map((n) => `- **${en[`q${n}.q`]}** ${en[`q${n}.a`]}`).join("\n")}

## Download (version ${VERSION})

${["mac", "ios", "tv"].map((p) => `- [${install.title[p]}](${DOWNLOADS[p]}): ${install.req[p]}. ${install.tag[p]}.`).join("\n")}
- [Install guide](${INSTALL_GUIDE}): installing the iPhone, iPad and Apple TV apps with Sideloadly, keeping them signed, and troubleshooting.

## Project

- [Website](${SITE_URL}/): features, install steps and FAQ.
- [Source code](${REPO}): the SwiftUI app, licensed under GPL-3.0.

## Optional

- [Intro film](${SITE_URL}/intro/): a 100-second animated tour of the app.
${LANGS.filter((l) => l !== "en").map((l) => `- [${LOCALES[l].name}](${pageUrl(l)}): the website in ${LANG_NAME_EN[l]}.`).join("\n")}
`;
await writeFile(join(dist, "llms.txt"), llms);

console.log(`prerendered ${LANGS.map((l) => LANG_PATH[l]).join(" ")} + sitemap.xml, llms.txt`);
