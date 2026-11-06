// 射手网 (assrt.net) through its API (https://assrt.net/api/doc), mostly Chinese subtitles. The viewer brings
// the API token from their assrt.net account; the API's quota is per account (20 requests a minute in its docs; new accounts
// have been seen with 5).
// A result is an upload, often a season's archive: `resolve` picks the episode's file from its file list.
const api = 'https://api.assrt.net/v1';

function token(context) {
    const value = context?.credentials?.token;
    if (!value) throw new SubtitleError('authRequired', 'Assrt needs an API token');
    return value;
}

// Assrt answers HTTP 200 or 400 with its own status.
function body(response, what) {
    let answer;
    try { answer = JSON.parse(response.text); } catch { throw SubtitleError.from(response, what); }
    const status = Number(answer.status ?? -1);
    if (status === 0) return answer;
    const message = String(answer.errmsg || '');
    if (status === 20000 || status === 20001 || /token/i.test(message)) throw new SubtitleError('authExpired', 'Assrt did not accept the token');
    if (status === 30900 || /limit|frequen/i.test(message)) throw new SubtitleError('rateLimited', 'Assrt limits requests per minute', 60);
    if (status === 101 || status === 30000) throw new SubtitleError('noResults', message);
    throw new SubtitleError('failed', `${what} failed (${status})`);
}

function language(lang) {
    const list = lang?.langlist || {};
    if (list.langchs || list.langdou) return 'zh-Hans';
    if (list.langcht) return 'zh-Hant';
    if (list.langeng) return 'en';
    if (list.langjap) return 'ja';
    if (list.langkor) return 'ko';
    const text = String(lang?.desc || '');
    if (/简|双语/.test(text)) return 'zh-Hans';
    if (/繁/.test(text)) return 'zh-Hant';
    if (/英/.test(text)) return 'en';
    return '';
}

function format(text) {
    const value = String(text || '').toLowerCase();
    if (value.includes('ass') || value.includes('ssa')) return 'ass';
    if (value.includes('srt') || value.includes('subrip')) return 'srt';
    if (value.includes('vtt')) return 'vtt';
    return undefined;
}

function episodeOf(name) {
    const text = String(name || '');
    const match = text.match(/[Ss](\d{1,2})[ ._-]?[Ee](\d{1,4})/) || text.match(/(?:^|[^a-z0-9])[Ee][Pp]?(\d{1,4})(?:[^0-9]|$)/) || text.match(/第\s*(\d{1,4})\s*[集话話回]/);
    if (!match) return null;
    return match.length > 2 && match[2] ? { season: Number(match[1]), episode: Number(match[2]) } : { season: null, episode: Number(match[1]) };
}

const subtitleSource = {
    manifest: {
        schema: 1, id: 'assrt', name: '射手网 (Assrt)', version: '1', minimumHost: 1,
        domains: ['assrt.net'],
        languages: ['zh-Hans', 'zh-Hant', 'en'],
        homepage: 'https://assrt.net/usercp.php',
        credentials: [{ key: 'token', title: 'API Token', secret: true, required: true, note: 'assrt.net › 用户中心' }],
    },

    async search(hint, context) {
        const byFile = !!hint.fileName && /[Ss]\d{1,2}[Ee]\d{1,4}|\d{3,4}p/.test(hint.fileName);
        let q = byFile ? hint.fileName : String(hint.title || '');
        if (!byFile && hint.episode != null && /^[\x00-\x7f]+$/.test(q)) {
            q += ` S${String(hint.season ?? 1).padStart(2, '0')}E${String(hint.episode).padStart(2, '0')}`;
        }
        // Assrt wants at least three characters.
        if (q.trim().length < 3) q = q.trim().padEnd(3, ' ');
        const response = await $http.get(api + '/sub/search', { query: { token: token(context), q, cnt: 15, pos: 0, is_file: byFile ? 1 : 0 } });
        const answer = body(response, 'Assrt search');
        const wanted = hint.episode != null ? { season: hint.season ?? 1, episode: hint.episode } : null;
        return (answer.sub?.subs || []).map(sub => {
            const title = sub.videoname || sub.native_name || '';
            const found = episodeOf(title);
            return {
                id: String(sub.id), title, language: language(sub.lang), format: format(sub.subtype),
                season: found?.season ?? undefined, episode: found?.episode ?? undefined,
                // The episode wanted, for picking it out of a season's archive.
                token: wanted ? JSON.stringify(wanted) : undefined,
            };
        });
    },

    async resolve(candidate, context) {
        const response = await $http.get(api + '/sub/detail', { query: { token: token(context), id: candidate.key } });
        const answer = body(response, 'Assrt download');
        const sub = answer.sub?.subs?.[0];
        if (!sub) throw new SubtitleError('downloadFailed', 'Assrt has no such upload');
        const wanted = candidate.token ? JSON.parse(candidate.token) : null;
        const files = (sub.filelist || []).filter(file => /\.(srt|ass|ssa|vtt)$/i.test(file.f || ''));
        const rank = file => {
            let score = 0;
            const found = episodeOf(file.f);
            if (wanted && found) score += found.episode === wanted.episode && (found.season == null || found.season === wanted.season) ? 100 : -100;
            if (/\.ass$|\.ssa$/i.test(file.f)) score += 2;
            if (/chs|简|sc\b|zh-?cn/i.test(file.f)) score += 3;
            return score;
        };
        const best = files.sort((a, b) => rank(b) - rank(a))[0];
        if (best && (!wanted || rank(best) >= 0)) return { url: best.url, name: best.f, format: format(best.f) };
        if (!files.length && /\.(srt|ass|ssa|vtt)$/i.test(sub.filename || '') && sub.url) return { url: sub.url, name: sub.filename, format: format(sub.filename) };
        throw new SubtitleError('downloadFailed', wanted ? 'This upload has no file for the episode' : 'This upload is an archive only');
    },
};
