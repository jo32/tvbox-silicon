# Yingxia website

The website for Yingxia: React 19 + TypeScript, built with Vite and deployed to Cloudflare as a static-assets Worker (`@cloudflare/vite-plugin` + Wrangler). There is no server code.

```sh
npm install
npm run dev        # Vite dev server with hot reload
npm run preview    # production build served by workerd, Cloudflare's runtime
npm run typecheck
npm run deploy     # build, then `wrangler deploy` (run `npx wrangler login` once first)
```

The Worker is named `yingxia-website` in `wrangler.jsonc` and serves https://yingxia.getmegaportal.com. Unknown paths get `public/404.html` with a 404 status (`not_found_handling: 404-page`).

## SEO and prerendering

`npm run build:site` (used by `build`, `preview` and `deploy`) runs `vite build`, then `scripts/prerender.mjs`, which renders the homepage once per language into `dist/` (`/`, `/ja/`, `/ko/`, `/zh-hant/`; paths in `src/site.ts`). Each page gets its own title, description, canonical URL, hreflang links, Open Graph tags and JSON-LD (`SoftwareApplication` and `FAQPage`), and the client hydrates it. The root page is English and switches to a saved or browser language after load, moving the address to that language's page; `?lang=` links still work. The script also writes `sitemap.xml` and `llms.txt` from the same strings and download links, so bumping `MAC_DOWNLOAD`/`DOWNLOADS` or editing the FAQ updates them. `public/robots.txt` points to the sitemap. `vite dev` serves the unrendered app.

## Layout

| Path | Purpose |
| --- | --- |
| `src/i18n/strings.ts` | All copy for English, Japanese, Korean, and Traditional Chinese |
| `src/i18n/I18nProvider.tsx` | Language detection (`?lang=`, saved choice, browser languages) and the `useI18n` hook |
| `src/components/` | Page sections (`Nav`, `Hero`, `Features`, `Details`, `Faq`, `Footer`) and shared pieces (`Headline`, `Stage`, `Reveal`, `controls`) |
| `src/styles.css` | All styles |
| `public/screenshots/<language>/` | tvOS screenshots shown on the page |

Fonts (Inter, Instrument Serif) are self-hosted through Fontsource. Japanese, Korean, and Chinese headlines use the system's Mincho, Myungjo, or Song serif.

The source repository (`REPO` in `src/components/controls.tsx`) is linked from the nav, the footer, the install guide, the JSON-LD and `llms.txt`.

## Screenshots

`public/screenshots/<language>/{home,live,search,site}.jpg` are 1920×1080 captures of the debug tvOS app on an Apple TV 4K (1080p) simulator, launched with `-AppleLanguages (<language>)` and the `QALaunch` hooks:

| Shot | Launch arguments |
| --- | --- |
| home | `-qaSection home` |
| live | `-qaSection live -qaPage channels:1` |
| search | `-qaSection search -qaPage search:<query>` |
| site | `-qaSection sites -qaPage site:<source key>` |

Capture with `xcrun simctl io <device> screenshot`. The app has no Korean localization yet, so the Korean page uses the English screenshots (`shots: "en"` in `strings.ts`); add `public/screenshots/ko/` and change it once the app supports Korean.
