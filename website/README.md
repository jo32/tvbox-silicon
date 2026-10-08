# Yingxia website

The "coming soon" site for Yingxia: React 19 + TypeScript, built with Vite and deployed to Cloudflare as a static-assets Worker (`@cloudflare/vite-plugin` + Wrangler). There is no server code.

```sh
npm install
npm run dev        # Vite dev server with hot reload
npm run preview    # production build served by workerd, Cloudflare's runtime
npm run typecheck
npm run deploy     # build, then `wrangler deploy` (run `npx wrangler login` once first)
```

The Worker is named `yingxia-website` in `wrangler.jsonc`. Unknown paths fall back to the app (`not_found_handling: single-page-application`). Attach a custom domain in the Cloudflare dashboard or with a `routes` entry in `wrangler.jsonc`.

## Layout

| Path | Purpose |
| --- | --- |
| `src/i18n/strings.ts` | All copy for English, Japanese, Korean, and Traditional Chinese |
| `src/i18n/I18nProvider.tsx` | Language detection (`?lang=`, saved choice, browser languages) and the `useI18n` hook |
| `src/components/` | Page sections (`Nav`, `Hero`, `Features`, `Details`, `Faq`, `Footer`) and shared pieces (`Headline`, `Stage`, `Reveal`, `controls`) |
| `src/styles.css` | All styles |
| `public/screenshots/<language>/` | tvOS screenshots shown on the page |

Fonts (Inter, Instrument Serif) are self-hosted through Fontsource. Japanese, Korean, and Chinese headlines use the system's Mincho, Myungjo, or Song serif.

The page says "coming soon" and links nowhere else while the repository is private. When Yingxia launches, replace `SoonPill` in `src/components/controls.tsx` with a real download or repository link, and update the `soon`, `hero.badge`, `hero.meta`, `q6`, and `cta` strings.

## Screenshots

`public/screenshots/<language>/{home,live,search,site}.jpg` are 1920×1080 captures of the debug tvOS app on an Apple TV 4K (1080p) simulator, launched with `-AppleLanguages (<language>)` and the `QALaunch` hooks:

| Shot | Launch arguments |
| --- | --- |
| home | `-qaSection home` |
| live | `-qaSection live -qaPage channels:1` |
| search | `-qaSection search -qaPage search:<query>` |
| site | `-qaSection sites -qaPage site:<source key>` |

Capture with `xcrun simctl io <device> screenshot`. The app has no Korean localization yet, so the Korean page uses the English screenshots (`shots: "en"` in `strings.ts`); add `public/screenshots/ko/` and change it once the app supports Korean.
