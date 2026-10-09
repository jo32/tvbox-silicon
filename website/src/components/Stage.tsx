import { useI18n } from "../i18n/I18nProvider";

interface Props {
  /** Screenshot name under public/screenshots/<language>/. */
  shot: string;
  alt: string;
  hero?: boolean;
}

/** A tvOS screenshot on a TV with its stand, shown plainly like a product shot. */
export function Stage({ shot, alt, hero = false }: Props) {
  const { shot: shotURL } = useI18n();
  return (
    <div className={hero ? "stage stage-hero" : "stage"}>
      <figure className="tv">
        <img src={shotURL(shot)} alt={alt} width={1920} height={1080} loading={hero ? "eager" : "lazy"} />
      </figure>
      <div className="tv-stand" aria-hidden="true" />
    </div>
  );
}
