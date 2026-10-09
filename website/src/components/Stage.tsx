import { useI18n } from "../i18n/I18nProvider";

interface Props {
  /** Screenshot name; the image is public/devices/tv-<shot>-<language>.webp. */
  shot: string;
  alt: string;
}

/** A tvOS screenshot on Apple's Apple TV product bezel (TV, Apple TV 4K and Siri Remote). */
export function Stage({ shot, alt }: Props) {
  const { locale } = useI18n();
  return (
    <div className="stage">
      <img src={`/devices/tv-${shot}-${locale.shots}.webp`} alt={alt} width={1600} height={994} loading="lazy" />
    </div>
  );
}
