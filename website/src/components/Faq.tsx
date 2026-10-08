import { useState } from "react";
import { useI18n } from "../i18n/I18nProvider";
import type { TextKey } from "../i18n/strings";
import { Headline } from "./Headline";
import { Reveal } from "./Reveal";

const QUESTIONS = [1, 2, 3, 4, 5, 6].map((n) => ({ q: `q${n}.q` as TextKey, a: `q${n}.a` as TextKey }));

export function Faq() {
  const { t } = useI18n();
  const [open, setOpen] = useState<number | null>(null);

  return (
    <section className="section narrow" id="faq">
      <Reveal>
        <Headline lines={["faq.l1", "faq.l2"]} small />
      </Reveal>
      <Reveal className="faq">
        {QUESTIONS.map(({ q, a }, i) => (
          <details
            key={q}
            open={open === i}
            onToggle={(e) => {
              // Keep one answer open at a time.
              if (e.currentTarget.open) setOpen(i);
              else if (open === i) setOpen(null);
            }}
          >
            <summary>{t(q)}</summary>
            <p>{t(a)}</p>
          </details>
        ))}
      </Reveal>
    </section>
  );
}
