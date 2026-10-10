// Build-time entry for scripts/prerender.mjs: renders a language page to HTML and exposes the
// copy and links the script needs for the page head, sitemap.xml and llms.txt.
import { renderToString } from "react-dom/server";
import { App } from "./App";
import { I18nProvider } from "./i18n/I18nProvider";
import type { Lang } from "./i18n/strings";

export function render(lang: Lang): string {
  return renderToString(
    <I18nProvider renderedLang={lang}>
      <App />
    </I18nProvider>,
  );
}

export { DOWNLOADS, INSTALL_GUIDE, MAC_DOWNLOAD, REPO } from "./components/controls";
export { INSTALL } from "./i18n/install-strings";
export { LANGS, LOCALES } from "./i18n/strings";
export { LANG_PATH, SITE_URL } from "./site";
