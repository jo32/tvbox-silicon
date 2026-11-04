// Hongguo's public web catalog plus the signed app playback adapter.
// Endpoint/response reference: jackotom/hongguo-drama, see hongguo/NOTICE.txt.
import { fetchAppPlayUrl } from './hongguo/app-source.js';
import * as cheerio from 'assets://js/lib/cheerio.min.js';

const SITE = 'https://hongguoduanju.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15';
const headers = { 'User-Agent': UA, Referer: SITE + '/' };
const categories = ['real-drama', 'comic-drama', 'ai-drama', 'hot-drama', 'hot-real-drama', 'hot-comic-drama', 'hot-ai-drama'];
let labels = {};
const fail = key => { throw new Error(labels[key] || 'Hongguo is temporarily unavailable. Please try again.'); };
const validID = value => typeof value === 'string' && /^[0-9]{1,30}$/.test(value);

function html(url) {
    // From mainland China, a third to a half of new connections to the site stall (no body, or a body
    // that stops) and never recover, and its gateway now and then answers 502 "upstream_unavailable".
    // So up to four connections race, 2 s apart; a failed one starts the next at once, and the first
    // answer below 500 wins. On the direct path this took 23 of 24 loads, against 15 of 24 before.
    const result = globalThis.req(url, { headers, timeout: 8000, racers: 4, hedge: 2000 });
    if (result.code !== 200 || !result.content || result.content.length > 8 * 1024 * 1024) fail('unavailable');
    return result.content;
}

// Read a balanced JSON object, never evaluate a remote script.
export function routerData(text) {
    const match = /(?:window\.)?_ROUTER_DATA\s*=\s*(\{)/.exec(text);
    if (!match) fail('changed');
    const start = match.index + match[0].length - 1;
    let depth = 0, quoted = false, escaped = false;
    for (let i = start; i < text.length; i++) {
        const c = text[i];
        if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
        else if (c === '"') quoted = true;
        else if (c === '{') depth++;
        else if (c === '}' && --depth === 0) return JSON.parse(text.slice(start, i + 1));
    }
    fail('changed');
}

function loader(text, predicate) {
    const data = Object.values(routerData(text).loaderData || {}).find(value => value && predicate(value));
    if (!data || data.isSuccess === false) fail('changed');
    return data;
}

function decodeHTML(value) {
    return value.replace(/&(#x[0-9a-f]+|#\d+|quot|apos|amp|lt|gt);/gi, (entity, key) => {
        if (key[0] !== '#') return ({ quot: '"', apos: "'", amp: '&', lt: '<', gt: '>' })[key.toLowerCase()];
        const code = key[1].toLowerCase() === 'x' ? parseInt(key.slice(2), 16) : Number(key.slice(1));
        return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
    });
}

function cards(items) {
    const seen = new Set();
    return items.map(row => row.video_data || row).flatMap(row => {
        const id = row.series_id || row.seriesId;
        const title = row.series_name || row.series_title || row.title;
        if (!validID(id) || typeof title !== 'string' || !title.trim() || seen.has(id)) return [];
        seen.add(id);
        return [{ vod_id: id, vod_name: title.trim(), vod_pic: row.series_cover || row.cover || '',
            vod_remarks: [row.rank ? `#${row.rank}` : '', row.episode_right_text || '', row.heatText || ''].filter(Boolean).join(' · '),
            vod_content: row.series_intro || row.description || '' }];
    });
}

export function catalog(text, category, page) {
    let data;
    if (category.startsWith('hot-')) {
        // Streaming SSR carries JSON inside an HTML-encoded script attribute.
        for (const match of text.matchAll(/<script\b([^>]*)>/gi)) {
            if (!/data-fn-name=["']mergeLoaderData["']/.test(match[1])) continue;
            const attribute = match[1].match(/data-fn-args=(?:"([^"]*)"|'([^']*)')/);
            if (!attribute) continue;
            try {
                const args = JSON.parse(decodeHTML(attribute[1] ?? attribute[2]));
                if (args[0] !== `rank_${category}/page` || !Array.isArray(args[1])) continue;
                const content = args[1].find(item => item.key === 'content' && item.routerDataFnName === 'p');
                if (content?.routerDataFnArgs?.[0]) data = JSON.parse(content.routerDataFnArgs[0]);
            } catch { /* A different streamed payload may precede the ranking. */ }
        }
        if (!data || data.isSuccess === false || !Array.isArray(data.rankList)) {
            // Some responses render the cards but omit the resolved streaming payload.
            const $ = cheerio.load(text), rankList = [];
            $('article').each((_, article) => {
                const node = $(article), heading = node.find('h2[id^="rank-title-"]').first();
                const id = String(heading.attr('id') || '').replace('rank-title-', '');
                if (!validID(id) || !node.find(`a[href*="series_id=${id}"]`).length) return;
                const rank = Number(node.find('span').first().text());
                if (!Number.isSafeInteger(rank) || rank < 1) return;
                rankList.push({ seriesId: id, title: heading.text().trim(), cover: node.find('img').first().attr('src') || '', rank });
            });
            if (!rankList.length) fail('changed');
            let totalPages = page;
            $('nav[aria-label="榜单分页"] a[href]').each((_, link) => {
                try {
                    const url = new URL($(link).attr('href'), SITE);
                    if (url.origin === SITE && url.pathname === `/rank/${category}`) totalPages = Math.max(totalPages, Number(url.searchParams.get('page')) || 1);
                } catch { /* Ignore unrelated navigation. */ }
            });
            data = { rankList, pagination: { totalPages } };
        }
    } else {
        data = loader(text, item => item.categoryRoute?.contentType === category);
        if (!Array.isArray(data.recommendList)) fail('changed');
    }
    return { list: cards(data.rankList || data.recommendList), page,
        pagecount: Math.max(1, Number(data.pagination?.totalPages) || 1) };
}

export function detail(text, id) {
    const data = loader(text, item => item.seriesDetail?.series_id === id);
    const series = data.seriesDetail;
    const video = cards([series])[0];
    if (!video || !Array.isArray(series.vid_list) || !series.vid_list.length || !series.vid_list.every(validID)) fail('changed');
    // Keep every episode, including those beyond the website's preview window.
    video.vod_play_from = labels.name || 'Hongguo';
    video.vod_play_url = series.vid_list.map((vid, index) => `${(labels.episode || 'Episode %@').replace('%@', String(index + 1))}$${id}/${vid}`).join('#');
    return { list: [video] };
}

// The search page now renders in the browser; its results come from this JSON endpoint.
export function search(text, page) {
    let data;
    try { data = JSON.parse(text); } catch { fail('changed'); }
    if (!data || !Array.isArray(data.searchList)) fail('changed');
    // totalPages changes from page to page, so only trust it while hasMore says there is a next page.
    const pagecount = data.hasMore === true ? Math.max(page + 1, Number(data.totalPages) || 0) : page;
    return { list: cards(data.searchList), page, pagecount };
}

export function webMedia(text, id, vid) {
    const data = loader(text, item => item.seriesDetail?.series_id === id);
    if (String(data.vid) !== vid) return null;
    // A protected episode's public file is a 10 s preview, even though the metadata gives the full duration.
    if (data.protectedPlayback === true || data.publicVideoSeo?.available === false) return null;
    // Prefer exact-episode structured video metadata, not a recommendation's main_url.
    for (const match of text.matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
        let root; try { root = JSON.parse(match[1]); } catch { continue; }
        const visit = value => {
            if (!value || typeof value !== 'object') return null;
            if (value['@type'] === 'VideoObject' && typeof value.contentUrl === 'string') {
                const url = new URL(value.contentUrl, SITE);
                const episodePath = `/player/${id}/${vid}`;
                const identity = String(value['@id'] || '') + String(value.about?.['@id'] || '');
                if (url.protocol === 'https:' && (identity.includes(episodePath) || url.pathname.includes(`/${vid}/`))) return url.href;
            }
            for (const child of Object.values(value)) { const url = visit(child); if (url) return url; }
            return null;
        };
        const url = visit(root); if (url) return url;
    }
    return null;
}

export default {
    init(ext) { labels = typeof ext === 'string' ? JSON.parse(ext || '{}') : ext || {}; },
    home() { return { class: categories.map((id, index) => ({ type_id: id, type_name: labels.categories?.[index] || id })) }; },
    homeVod() { return this.category('real-drama', 1); },
    category(id, pg) {
        if (!categories.includes(id)) fail('changed');
        const page = Math.max(1, parseInt(pg, 10) || 1);
        // `?page=1` redirects to the bare path, an extra round trip.
        return catalog(html(`${SITE}/${id.startsWith('hot-') ? 'rank' : 'category'}/${id}${page > 1 ? `?page=${page}` : ''}`), id, page);
    },
    search(query, quick, pg) {
        const page = Math.max(1, parseInt(pg, 10) || 1);
        const params = `query=${encodeURIComponent(String(query).trim())}${page > 1 ? `&page=${page}` : ''}`;
        return search(html(`${SITE}/api/search/result?${params}`), page);
    },
    detail(id) { if (!validID(id)) fail('changed'); return detail(html(`${SITE}/player/${id}`), id); },
    async play(flag, address) {
        const parts = String(address).split('/');
        if (parts.length !== 2 || !parts.every(validID)) fail('changed');
        const [id, vid] = parts;
        // App playback provides full-series sources and higher quality when available.
        try {
            const result = await fetchAppPlayUrl(vid);
            return { parse: 0, url: result.url, hongguoKey: result.contentKey, hongguoBackups: result.backups, header: result.headers };
        } catch { /* Use the exact episode's public webpage when the app endpoint is unavailable. */ }
        try {
            const url = webMedia(html(`${SITE}/player/${id}/${vid}`), id, vid);
            if (url) return { parse: 0, url, header: headers };
        } catch { /* Report one localized error without exposing signed URLs or keys. */ }
        fail('playback');
    },
};
