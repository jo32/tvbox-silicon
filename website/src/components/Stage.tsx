import { useI18n } from "../i18n/I18nProvider";

export type StageTone = "dawn" | "dusk" | "night";

interface Props {
  /** Screenshot name under public/screenshots/<language>/. */
  shot: string;
  alt: string;
  tone?: StageTone;
  hero?: boolean;
}

/** A tvOS screenshot shown on a TV, set against a wallpaper gradient. */
export function Stage({ shot, alt, tone = "dawn", hero = false }: Props) {
  const { shot: shotURL } = useI18n();
  const className = ["stage", tone !== "dawn" && tone, hero && "stage-hero"].filter(Boolean).join(" ");
  return (
    <div className={className}>
      <figure className="tv">
        <img src={shotURL(shot)} alt={alt} width={1920} height={1080} loading={hero ? "eager" : "lazy"} />
      </figure>
    </div>
  );
}
