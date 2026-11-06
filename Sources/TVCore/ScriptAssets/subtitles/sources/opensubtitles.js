// OpenSubtitles.com through its REST API (https://opensubtitles.stoplight.io/docs/opensubtitles-api).
// The viewer brings an API key (opensubtitles.com › Consumers); a user name and password raise the daily
// download quota from the anonymous one. Pitfall: the API redirects (301) unless query parameters are sorted
// by name and lowercase.
const api = 'https://api.opensubtitles.com/api/v1';
const agent = 'Yingxia v1';
let account = null; // { identity, token, base, until }

const toSite = { 'zh-Hans': 'zh-cn', 'zh-Hant': 'zh-tw', 'pt-BR': 'pt-br', pt: 'pt-pt' };
const fromSite = { 'zh-cn': 'zh-Hans', 'zh-tw': 'zh-Hant', ze: 'zh', 'pt-br': 'pt-BR', 'pt-pt': 'pt' };

function headers(context, token) {
    const key = context?.credentials?.apiKey;
    if (!key) throw new SubtitleError('authRequired', 'OpenSubtitles needs an API key');
    const out = { 'Api-Key': key, 'User-Agent': agent, Accept: 'application/json' };
    if (token) out.Authorization = 'Bearer ' + token;
    return out;
}

function failure(response, what) {
    if (response.status === 403) return new SubtitleError('authRequired', 'OpenSubtitles did not accept the API key');
    if (response.status === 406) {
        let reset;
        try { reset = Date.parse(response.json().reset_time_utc); } catch {}
        return new SubtitleError('rateLimited', 'The download quota for today is used up', reset ? Math.max(1, Math.round((reset - Date.now()) / 1000)) : undefined);
    }
    return SubtitleError.from(response, what);
}

// Signs in when the viewer gave a user name and password; the token lasts a day.
async function signIn(context) {
    const { username, password, apiKey } = context?.credentials || {};
    if (!username || !password) return null;
    const identity = [apiKey, username, password].join('\n');
    if (account && account.identity === identity && Date.now() < account.until) return account;
    const response = await $http.post(api + '/login', { username, password }, { headers: headers(context) });
    if (response.status === 401) throw new SubtitleError('authExpired', 'OpenSubtitles did not accept the user name or password');
    if (!response.ok) throw failure(response, 'OpenSubtitles sign-in');
    const body = response.json();
    account = { identity, token: body.token, base: body.base_url ? `https://${body.base_url}/api/v1` : api, until: Date.now() + 20 * 3600 * 1000 };
    return account;
}

function sorted(query) {
    const out = {};
    for (const key of Object.keys(query).sort()) if (query[key] != null && query[key] !== '') out[key] = query[key];
    return out;
}

const subtitleSource = {
    manifest: {
        schema: 1, id: 'opensubtitles', name: 'OpenSubtitles', version: '1', minimumHost: 1,
        domains: ['opensubtitles.com', 'opensubtitles.org'],
        languages: ['en', 'zh-Hans', 'zh-Hant', 'es', 'fr', 'de', 'ja', 'ko', 'pt-BR'],
        homepage: 'https://www.opensubtitles.com/en/consumers',
        credentials: [
            { key: 'apiKey', title: 'API Key', secret: true, required: true, note: 'opensubtitles.com › API Consumers' },
            { key: 'username', title: 'User Name', secret: false, required: false },
            { key: 'password', title: 'Password', secret: true, required: false },
        ],
    },

    async search(hint, context) {
        const episode = hint.episode != null;
        const languages = [...new Set((hint.languages || []).map(code => toSite[code] || String(code).toLowerCase()))].sort().join(',');
        const query = { languages };
        if (hint.tmdbID) query[episode ? 'parent_tmdb_id' : 'tmdb_id'] = hint.tmdbID;
        else if (hint.imdbID) query[episode ? 'parent_imdb_id' : 'imdb_id'] = String(hint.imdbID).replace(/^tt/, '');
        else query.query = String(hint.title || '').toLowerCase();
        if (episode) { query.episode_number = hint.episode; query.season_number = hint.season ?? 1; }
        else if (hint.year) query.year = hint.year;
        const session = await signIn(context);
        const response = await $http.get((session?.base || api) + '/subtitles', { query: sorted(query), headers: headers(context, session?.token) });
        if (response.status === 401 && session) { account = null; throw new SubtitleError('authExpired', 'OpenSubtitles signed out'); }
        if (!response.ok) throw failure(response, 'OpenSubtitles search');
        const results = [];
        for (const item of response.json().data || []) {
            const a = item.attributes || {};
            const file = (a.files || [])[0];
            if (!file) continue;
            const feature = a.feature_details || {};
            const language = String(a.language || '').toLowerCase();
            results.push({
                id: String(file.file_id), title: a.release || file.file_name || feature.title || '',
                language: fromSite[language] || language, format: 'srt',
                forced: !!a.foreign_parts_only, hearingImpaired: !!a.hearing_impaired,
                season: feature.season_number || undefined, episode: feature.episode_number || undefined,
                fileMatch: !!a.moviehash_match, downloads: a.download_count || 0,
            });
        }
        return results;
    },

    async resolve(candidate, context) {
        const session = await signIn(context);
        const response = await $http.post((session?.base || api) + '/download', { file_id: Number(candidate.key) },
            { headers: headers(context, session?.token) });
        if (response.status === 401) { account = null; throw new SubtitleError(session ? 'authExpired' : 'authRequired', 'OpenSubtitles wants you signed in to download'); }
        if (!response.ok) throw failure(response, 'OpenSubtitles download');
        const body = response.json();
        if (!body.link) throw new SubtitleError('downloadFailed', body.message || 'No download link');
        // The link is good for a few hours.
        return { url: body.link, name: body.file_name || candidate.title, format: 'srt', expires: Date.now() + 2 * 3600 * 1000 };
    },
};
