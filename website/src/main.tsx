import "@fontsource/inter/400.css";
import "@fontsource/inter/500.css";
import "@fontsource/inter/600.css";
import "@fontsource/inter/700.css";
import "@fontsource/instrument-serif/400-italic.css";
import "./styles.css";

import { StrictMode } from "react";
import { createRoot, hydrateRoot } from "react-dom/client";
import { App } from "./App";
import { isLang } from "./i18n/detect";
import { I18nProvider } from "./i18n/I18nProvider";

// The build prerenders each language page (scripts/prerender.mjs); `vite dev` serves an empty #root.
const root = document.getElementById("root")!;
const rendered = root.dataset.lang ?? null;
const app = (
  <StrictMode>
    <I18nProvider renderedLang={isLang(rendered) ? rendered : undefined}>
      <App />
    </I18nProvider>
  </StrictMode>
);

if (root.firstElementChild) hydrateRoot(root, app);
else createRoot(root).render(app);
