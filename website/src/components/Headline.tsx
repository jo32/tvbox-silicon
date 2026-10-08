import type { CSSProperties } from "react";
import { useI18n } from "../i18n/I18nProvider";
import type { TextKey } from "../i18n/strings";

interface Props {
  /** Sans-serif first line and serif second line. */
  lines: [TextKey, TextKey];
  as?: "h1" | "h2";
  small?: boolean;
  /** Blur each word in on mount (and again when the language changes). */
  animate?: boolean;
}

// Split into words, or into word segments for CJK, keeping trailing spaces and punctuation attached.
function words(text: string, lang: string): string[] {
  const parts =
    typeof Intl.Segmenter === "function"
      ? [...new Intl.Segmenter(lang, { granularity: "word" }).segment(text)].map((s) => s.segment)
      : text.split(/(\s+)/);
  const out: string[] = [];
  for (const part of parts) {
    if (out.length && /^[\p{P}\s]+$/u.test(part)) out[out.length - 1] += part;
    else out.push(part);
  }
  return out;
}

export function Headline({ lines, as: Tag = "h2", small = false, animate = false }: Props) {
  const { t, lang } = useI18n();
  const className = ["headline", small && "small", animate && "animate"].filter(Boolean).join(" ");
  let index = 0;

  return (
    <Tag className={className} key={animate ? lang : undefined}>
      {lines.map((key, line) => (
        <span key={key} className={line === 0 ? "sans" : "serif"}>
          {animate
            ? words(t(key), lang).map((word, i) => (
                <span key={i} className="w" style={{ "--i": index++ } as CSSProperties}>
                  {word}
                </span>
              ))
            : t(key)}
        </span>
      ))}
    </Tag>
  );
}
