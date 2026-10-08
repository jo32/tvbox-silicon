// Standalone intro page (/intro/): the film, a back link, and ?t= / ?lang= support.
import "@fontsource/inter/400.css";
import "@fontsource/inter/500.css";
import "@fontsource/inter/600.css";
import "@fontsource/inter/700.css";
import "./page.css";
import { detectLang } from "../i18n/detect";
import { mountFilm } from "./film";
import { tr } from "./film-i18n";

const lang = detectLang();
const brand = lang === "ja" || lang === "zh-Hant" ? "映匣" : "Yingxia";
document.documentElement.lang = lang;
document.title = tr(lang, "How Yingxia works").replace("Yingxia", brand);
document.querySelector("#back")!.textContent = `← ${brand}`;
document.querySelector("#how")!.textContent = tr(lang, "How it works");

const at = new URLSearchParams(location.search).get("t");
mountFilm(document.getElementById("film-host")!, {
  lang,
  keys: true,
  startAt: at === null ? undefined : Number(at) || 0,
});
