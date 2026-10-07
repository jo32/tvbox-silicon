// 三六影视 (csp_Kan360): 360kan's web API lists and details; episodes are platform page URLs (爱奇艺, 优酷, ...)
// sent through the parse URL. The parse reply is used directly when it carries a media URL, otherwise the
// player gets parse=1 with the parse page. Uses the JAR's defaults (parse on, LS SH 19 HX DY XG hidden);
// the JAR's interactive settings dialogs are not ported.
// ext: {"filter": "<filters JSON URL>", "fishjx": ["<parse URL prefix>", ...]}
const API = 'https://api.web.360kan.com/v1';
const HEADERS = { 'User-Agent': 'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36', Referer: 'https://www.360kan.com/' };
const SITES = { qiyi: 'QY', youku: 'YK', qq: 'TX', imgo: 'MG', leshi: 'LS', bilibili1: 'BL', sohu: 'SH', m1905: '19', huanxi: 'HX', douyin: 'DY', xigua: 'XG' };
const EXCLUDE = 'LS SH 19 HX DY XG';

let filterURL = '', parseURL = '', config = null;

const fetchText = url => { try { return String(globalThis.req(url, { headers: HEADERS, timeout: 15000 }).content || ''); } catch { return ''; } };
const fetchJSON = url => { try { return JSON.parse(fetchText(url) || '{}'); } catch { return {}; } };
const str = (o, k) => o && o[k] != null ? String(o[k]) : '';
const https = url => url.startsWith('http') ? url : 'https:' + url;
const join = list => (list || []).filter(v => typeof v !== 'object').map(String).join(',');
const flagOf = site => SITES[site] || site.slice(0, 2).toUpperCase();

function filterConfig() {
    if (config) return config;
    config = {};
    if (filterURL) { try { config = JSON.parse(fetchText(filterURL)) || {}; } catch { config = {}; } }
    return config;
}
// Episode lists answer with msg "Success" only some of the time; the JAR retries three times.
function episodesPage(url) {
    for (let i = 0; i < 3; i++) {
        const text = fetchText(url);
        if (text.includes('"msg":"Success"')) { try { return JSON.parse(text); } catch {} }
    }
    return {};
}
// The first http(s) "url" anywhere in a parse reply.
function mediaURL(o) {
    if (!o || typeof o !== 'object') return '';
    if (typeof o.url === 'string' && /^https?:\/\//.test(o.url)) return o.url;
    for (const value of Object.values(o)) if (value && typeof value === 'object' && !Array.isArray(value)) { const found = mediaURL(value); if (found) return found; }
    return '';
}

export default {
    init(ext) {
        let c = {};
        try { c = typeof ext === 'object' && ext ? ext : JSON.parse(String(ext || '{}')); } catch {}
        filterURL = str(c, 'filter');
        const parses = [].concat(c.fishjx || []).map(String).filter(Boolean);
        parseURL = parses[0] || 'https://jx.xmflv.com/?url=';
        config = null;
    },
    home(filter) {
        const c = filterConfig();
        let classes = Array.isArray(c.categories) ? c.categories.map(x => ({ type_id: str(x, 'id'), type_name: '360' + str(x, 'name') })) : [];
        if (!classes.length) classes = [['1', '360电影'], ['2', '360电视剧'], ['4', '360动漫'], ['3', '360综艺']].map(([type_id, type_name]) => ({ type_id, type_name }));
        const filters = {};
        if (filter) for (const [k, v] of Object.entries(c)) if (k !== 'categories') filters[k] = v;
        return { class: classes, filters };
    },
    homeVod() {
        const c = filterConfig();
        const first = Array.isArray(c.categories) && c.categories.length ? str(c.categories[0], 'id') : '1';
        return this.category(first, '1', false, {});
    },
    category(tid, pg, filter, extend = {}) {
        const page = parseInt(pg, 10) || 1;
        const e = extend || {};
        const data = fetchJSON(`${API}/filter/list?catid=${tid}&rank=${e.rank || ''}&cat=${encodeURIComponent(e.cat || '')}&year=${e.year || ''}&area=${encodeURIComponent(e.area || '')}&size=35&pageno=${page}`).data || {};
        const list = (data.movies || []).filter(Boolean).map(m => ({ vod_id: `${tid}|${str(m, 'id')}`, vod_name: str(m, 'title'), vod_pic: https(str(m, 'cdncover')), vod_remarks: str(m, 'comment') || str(m, 'pubdate') }));
        return { page, pagecount: page + 1, limit: 35, total: (page + 1) * 35, list };
    },
    detail(id) {
        const parts = String(id).split('|');
        const cat = parts.length > 1 ? parts[0] : '1', vid = parts.length > 1 ? parts[1] : parts[0];
        const base = `${API}/detail?cat=${cat}&id=${vid}`;
        const d = fetchJSON(base).data;
        if (!d) return { list: [], msg: 'No data' };
        const vod = {
            vod_id: String(id), vod_name: str(d, 'title'), vod_pic: https(str(d, 'cdncover')), type_name: join(d.moviecategory), vod_area: join(d.area),
            vod_director: join(d.director), vod_actor: join(d.actor), vod_content: str(d, 'description'), vod_year: str(d, 'pubdate'),
            vod_remarks: str(d, 'doubanscore') ? '豆瓣: ' + str(d, 'doubanscore') : ''
        };
        const froms = [], urls = [];
        const details = d.playlinksdetail;
        for (const site of (details && d.playlink_sites) || []) {
            const flag = flagOf(String(site));
            if (EXCLUDE.includes(flag)) continue;
            const episodes = [];
            if ('allepidetail' in d) {
                const info = episodesPage(`${base}&site=${site}&callback=`).data || {};
                const count = Number((info.allupinfo || {})[site]) || 0;
                for (let start = 0; start < count; start += 200) {
                    const end = Math.min(start + 200, count);
                    const chunk = ((episodesPage(`${base}&start=${start + 1}&end=${end}&site=${site}&callback=`).data || {}).allepidetail || {})[site] || [];
                    for (const e of chunk) if (str(e, 'url')) episodes.push(`第${str(e, 'playlink_num')}集$${str(e, 'url')}`);
                }
            } else if (Array.isArray(d.defaultepisode)) {
                d.defaultepisode.forEach((e, i) => { if (str(e, 'site') === site && str(e, 'url')) episodes.push(`${str(e, 'title') || `第${i + 1}集`}$${str(e, 'url')}`); });
            }
            if (!episodes.length && details[site] && str(details[site], 'default_url')) episodes.push('播放$' + str(details[site], 'default_url'));
            if (episodes.length) { froms.push(flag); urls.push(episodes.join('#')); }
        }
        if (froms.length) { vod.vod_play_from = froms.join('$$$'); vod.vod_play_url = urls.join('$$$'); }
        return { list: [vod] };
    },
    search(wd, quick, pg) {
        const page = parseInt(pg, 10) || 1;
        const rows = (((fetchJSON(`https://api.so.360kan.com/index?force_v=1&kw=${encodeURIComponent(wd)}&from=&pageno=${page}&v_ap=1&tab=all`).data || {}).longData || {}).rows) || [];
        return { list: rows.filter(Boolean).map(r => ({ vod_id: `${str(r, 'cat_id')}|${str(r, 'en_id')}`, vod_name: str(r, 'titleTxt') || str(r, 'title').replace(/<[^>]+>/g, ''), vod_pic: https(str(r, 'cover')), vod_remarks: str(r, 'cat_name') })) };
    },
    play(flag, id) {
        let url = String(id || '');
        if (!url || flag === '提示') return { parse: 0, url: '', msg: '无效的播放链接' };
        if (url.includes('?') && !url.includes('video?vid=')) url = url.split('?')[0];
        if (!parseURL) return { parse: 1, url };
        const target = parseURL + url;
        const reply = fetchText(target).trim();
        try { const media = mediaURL(JSON.parse(reply)); if (media) return { parse: 0, url: media }; } catch {}
        if (/^https?:\/\//.test(reply)) return { parse: 0, url: reply };
        return { parse: 1, url: target };
    }
};
