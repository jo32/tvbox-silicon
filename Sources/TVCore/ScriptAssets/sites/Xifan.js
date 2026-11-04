// Xifan (西饭) short dramas from its public app API: genres, lists, search and the episodes it gives away.
// Endpoints and fields follow jackotom/hongguo-drama v4.1 src/native/xifan.js; see hongguo/NOTICE.txt.
const API = 'https://xifan-api-cn.youlishipin.com';
const ID = /^[a-zA-Z0-9_-]{1,200}$/;
let labels = {};
let genreCache = null;
const fail = key => { throw new Error(labels[key] || 'Xifan is temporarily unavailable. Please try again.'); };
const text = value => String(value ?? '').replace(/<[^>]*>/g, '').trim();
const https = value => {
    try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url.href : ''; } catch { return ''; }
};
// Covers come as quality-20 WebP, blurry on a large screen; quality 80 is about 90 KB.
const cover = value => https(value).replace(/quality,Q_\d+/, 'quality,Q_80');
const once = () => { const seen = new Set(); return item => !seen.has(item.vod_id ?? item.type_id) && seen.add(item.vod_id ?? item.type_id); };

function request(path, params) {
    const query = Object.entries({ ...params, version: 2001001, androidVersionCode: 28 })
        .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join('&');
    const reply = globalThis.req(`${API}${path}?${query}`, { headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' }, timeout: 10000, redirect: false });
    if (reply.code !== 200 || !reply.content || reply.content.length > 8 * 1024 * 1024) fail('unavailable');
    let data;
    try { data = JSON.parse(reply.content); } catch { fail('changed'); }
    if (data?.ret !== 0 || !data.result || typeof data.result !== 'object') fail('changed');
    return data.result;
}

const contents = result => (Array.isArray(result.elements) ? result.elements : []).flatMap(element => Array.isArray(element?.contents) ? element.contents : []);

// A genre's id carries what its list asks for: category id, version and name.
export function genres(result) {
    const items = contents(result).flatMap(item => {
        const category = item.categoryItemVo;
        return category ? (Array.isArray(category.subCategories) ? category.subCategories : [category]) : [];
    }).filter(item => Number.isSafeInteger(item.categoryId) && item.categoryId > 0 && text(item.oppoCategory))
        .map(item => ({ type_id: `${item.categoryId}:${Number(item.version) || 1}:${text(item.oppoCategory)}`, type_name: text(item.oppoCategory) }))
        .filter(once());
    if (!items.length) fail('changed');
    return items;
}

function loadGenres() {
    if (!genreCache || genreCache.expires < Date.now()) genreCache = { items: genres(request('/xifan/drama/portalPage', { reqType: 'duanjuCategory' })), expires: Date.now() + 300000 };
    return genreCache.items;
}

function card(item) {
    return { vod_id: `${item.source}:${item.duanjuId}`, vod_name: text(item.title), vod_pic: cover(item.coverImageUrl),
        vod_remarks: Number(item.total) > 0 ? (labels.episodes || '%@ Episodes').replace('%@', String(item.total)) : '' };
}

export function list(result, page) {
    const videos = contents(result).map(item => item.duanjuVo)
        .filter(item => item && ID.test(String(item.source ?? '')) && ID.test(String(item.duanjuId ?? '')) && text(item.title))
        .map(card).filter(once());
    return { list: videos, page, pagecount: result.hasMore === true && videos.length ? page + 1 : page };
}

function info(id) {
    const [source, duanjuId] = String(id).split(':');
    if (!ID.test(source || '') || !ID.test(duanjuId || '') || String(id).split(':').length !== 2) fail('changed');
    const result = request('/xifan/drama/getDuanjuInfo', { source, duanjuId });
    if (result.source !== source || String(result.duanjuId) !== duanjuId || !Array.isArray(result.episodeList)) fail('changed');
    return result;
}

// Only the episodes Xifan gives away; a paid one would only fail to play.
export function detail(result, id) {
    const all = result.episodeList.filter(episode => ID.test(String(episode?.episodeId ?? ''))).sort((a, b) => (Number(a.index) || 0) - (Number(b.index) || 0));
    const free = all.filter(episode => episode.unlock === true && https(episode.playUrl));
    const video = { ...card({ ...result, source: id.split(':')[0], duanjuId: id.split(':')[1] }), vod_content: text(result.desc),
        vod_actor: (Array.isArray(result.actorList) ? result.actorList : []).map(actor => text(actor?.name)).filter(Boolean).join(','),
        type_name: (Array.isArray(result.categories) ? result.categories : []).map(text).filter(Boolean).slice(0, 4).join(',') };
    if (free.length < all.length) video.vod_remarks = (labels.free || '%@ of %@ episodes free').replace('%@', String(free.length)).replace('%@', String(all.length));
    if (free.length) {
        video.vod_play_from = labels.name || 'Xifan';
        // Xifan's episode titles are often the series' name or a number; the episode number is clearer.
        video.vod_play_url = free.map(episode => `${(labels.episode || 'Episode %@').replace('%@', String(Number(episode.index) || 0))}$${id}/${episode.episodeId}`).join('#');
    }
    return { list: [video] };
}

export default {
    init(ext) { labels = typeof ext === 'string' ? JSON.parse(ext || '{}') : ext || {}; },
    home() { return { class: loadGenres() }; },
    homeVod() { return this.category(loadGenres()[0].type_id, 1); },
    category(tid, pg) {
        const [categoryId, version, ...name] = String(tid).split(':');
        if (!/^\d{1,12}$/.test(categoryId) || !/^\d{1,6}$/.test(version) || !name.length) fail('changed');
        const page = Math.max(1, parseInt(pg, 10) || 1);
        return list(request('/xifan/drama/portalPage', { reqType: 'aggregationPage', offset: (page - 1) * 30,
            categoryId, categoryNames: name.join(':'), categoryVersion: version }), page);
    },
    search(query, quick, pg) {
        const page = Math.max(1, parseInt(pg, 10) || 1);
        return list(request('/xifan/search/getSearchList', { keyword: String(query).trim(), pageIndex: page }), page);
    },
    detail(id) { return detail(info(id), String(id)); },
    play(flag, address) {
        const parts = String(address).split('/');
        if (parts.length !== 2 || !ID.test(parts[1])) fail('changed');
        // Read the series again: whether an episode is free can change, and play links are per request.
        const episode = info(parts[0]).episodeList.find(item => String(item?.episodeId) === parts[1]);
        const url = episode?.unlock === true ? https(episode.playUrl) : '';
        if (!url) fail(episode ? 'locked' : 'changed');
        return { parse: 0, url, header: { 'User-Agent': 'Mozilla/5.0' } };
    },
};
