import "@fontsource/inter/400.css";
import "@fontsource/inter/500.css";
import "@fontsource/inter/600.css";
import "@fontsource/inter/700.css";
import "@fontsource/instrument-serif/400-italic.css";
import "./styles.css";

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { I18nProvider } from "./i18n/I18nProvider";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <I18nProvider>
      <App />
    </I18nProvider>
  </StrictMode>,
);
