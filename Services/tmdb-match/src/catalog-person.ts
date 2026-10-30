import { catalogItems } from "./catalog.ts";
import { image, type TMDB } from "./tmdb.ts";

const list = (value: unknown): any[] => Array.isArray(value) ? value : [];
const text = (value: unknown, max: number) => typeof value === "string" ? value.trim().slice(0, max) : "";
const date = (value: unknown) => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;

/** One typed work per title, retaining every contribution for the timeline's role filters. */
export function personWorks(credits: any) {
  const entries = [...list(credits?.cast).map(x => ({ ...x, contribution: "Acting" })),
    ...list(credits?.crew).map(x => ({ ...x, contribution: text(x.department, 80) || "Production" }))];
  const grouped = new Map<string, { item: ReturnType<typeof catalogItems>[number]; date: string | null; roles: string[]; departments: string[] }>();
  for (const entry of entries) {
    const item = catalogItems({ results: [entry] })[0];
    if (!item) continue;
    const key = `${item.mediaType}:${item.id}`;
    const work = grouped.get(key) ?? { item, date: date(item.mediaType === "tv" ? entry.first_air_date : entry.release_date), roles: [], departments: [] };
    const role = text(entry.character || entry.job, 160);
    if (role && !work.roles.includes(role)) work.roles.push(role);
    if (!work.departments.includes(entry.contribution)) work.departments.push(entry.contribution);
    grouped.set(key, work);
  }
  return [...grouped.values()].sort((a, b) => (b.date ?? "").localeCompare(a.date ?? "") || a.item.name.localeCompare(b.item.name));
}

export async function catalogPerson(tmdb: TMDB, id: number, language: string) {
  const value = await tmdb.get(`/person/${id}`, { language, append_to_response: "combined_credits,external_ids,translations" });
  if (!value || value.adult) throw new Error("Person unavailable");
  const translations = list(value.translations?.translations);
  const biography = text(value.biography, 12000) || text(translations.find(x => x.iso_639_1 === language.split("-")[0])?.data?.biography, 12000)
    || text(translations.find(x => x.iso_639_1 === "en")?.data?.biography, 12000);
  const instagram = text(value.external_ids?.instagram_id, 30);
  return { id, name: text(value.name, 200), profile: image(value.profile_path, "w500"), biography,
    birthday: date(value.birthday), birthplace: text(value.place_of_birth, 200), department: text(value.known_for_department, 80),
    instagram: /^[\w.]{1,30}$/.test(instagram) ? instagram : null, works: personWorks(value.combined_credits) };
}
