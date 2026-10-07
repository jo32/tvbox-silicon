// 比特 (fty csp_BttwooGuard): bttwo.life pages. Playback asks video/play with s = HMAC-SHA256(key = video id,
// "<play_id>:<ms>:<video id>") cut to 32 hex chars and k = base64url(userlink XOR "nbmovie2024secretkey").
// Episode ids keep the JAR's "{play_id=.., userlink=.., playUrl=..}" form so the JAR fallback can play them.
// ext: {"siteUrl": "https://..."} optional.
import { parseHTML, textOf, hmacSha256 } from './_lite.js';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const KEY = 'nbmovie2024secretkey';
const CLASSES = [['filter?classify=1&page=', '电影'], ['filter?classify=2&page=', '电视剧'], ['filter?classify=3&page=', '动漫']];

let host = 'https://www.bttwo.life/';
const page = (url, referer) => parseHTML(globalThis.req(url, { headers: { 'User-Agent': UA, ...(referer ? { Referer: referer } : {}) } }).content);

function cards($, selector, kind) {
    return $(selector).toArray().map(el => {
        const item = $(el);
        if (item.find('span:contains(VIP)').length) return null;
        const img = item.find('img.object-cover').first();
        const name = img.attr('alt') || '';
        if (!name.trim()) return null;
        const remark = kind === 'home' ? item.find('span.text-right').first() : kind === 'cate' ? item.find('span.text-text-muted').first() : null;
        return { vod_id: (item.find('a[href*=play]').first().attr('href') || '').replace(/^\//, ''), vod_name: name, vod_pic: img.attr('data-src') || '', vod_remarks: remark ? textOf(remark) : '' };
    }).filter(Boolean);
}
function playKey(userlink) {
    if (!userlink || userlink === '0') return '0';
    const key = Buffer.from(KEY, 'utf8'), data = Buffer.from(userlink, 'utf8');
    const out = Buffer.alloc(data.length);
    for (let i = 0; i < data.length; i++) out[i] = key[i % key.length] ^ data[i];
    return out.toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
}
const parseEpisode = text => Object.fromEntries(String(text).replace(/^\{|\}$/g, '').split(', ').map(p => { const i = p.indexOf('='); return [p.slice(0, i), p.slice(i + 1)]; }));

export default {
    init(ext) {
        try { const c = JSON.parse(String(ext || '{}')); if (String(c.siteUrl || '').startsWith('http')) host = c.siteUrl.replace(/\/?$/, '/'); } catch {}
    },
    home() {
        return { class: CLASSES.map(([type_id, type_name]) => ({ type_id, type_name })), list: cards(page(host), 'div[class*="4xl:grid-cols-8"] div[data-vod-id]', 'home') };
    },
    category(tid, pg) {
        return { list: cards(page(host + tid + (pg || '1')), 'div[data-vod-id]', 'cate') };
    },
    detail(id) {
        const url = host + id;
        const $ = page(url, url);
        const info = { vod_director: '', vod_actor: '', vod_content: '' };
        let writer = '';
        $('div[class="grid grid-cols-3 gap-2 text-xs"] div').each((_, el) => {
            const label = textOf($(el)).trim();
            const value = textOf($(el).next()).trim();
            if (label === '导演') info.vod_director = value;
            else if (label === '编剧') writer = value;
            else if (label === '主演') info.vod_actor = value.replace(/ /g, '');
        });
        info.vod_content = textOf($('p[class="text-xs text-text-secondary leading-relaxed"]').first());
        const userlink = (($('nav[id=navbar]').attr('x-data') || '').match(/userlink:'(.*?)',/) || [])[1] || '';
        const episodes = $('div[style] a[href*=play]').toArray().map(a => {
            const link = $(a);
            const playId = ((link.attr('@click.prevent') || '').match(/handleEpisodeClick\(.*?,\s*'(\d+)'.*?\)/) || [])[1] || '';
            return `${textOf(link.find('span[x-show]').first())}${'$'}{play_id=${playId}, userlink=${userlink}, playUrl=${(link.attr('href') || '').replace(/^\//, '')}}`;
        });
        return { list: [{ vod_id: id, vod_name: textOf($('h1').first()), vod_pic: '', vod_remarks: writer, ...info, vod_play_from: '自动', vod_play_url: episodes.join('#') }] };
    },
    search(wd) {
        return { list: cards(page(host + 'search?q=' + encodeURIComponent(wd)), 'div.group.relative', 'search') };
    },
    play(flag, id) {
        const e = parseEpisode(id);
        const video = String(e.playUrl || '').replace('play/', '');
        const time = String(Date.now());
        const sign = hmacSha256(`${e.play_id}:${time}:${video}`, video).slice(0, 32);
        const url = `${host}video/play?p=${e.play_id}&v=${video}&q=1080&s=${sign}&t=${time}&k=${playKey(e.userlink)}`;
        const urls = ((JSON.parse(globalThis.req(url, { headers: { 'User-Agent': UA } }).content || '{}').data || {}).quality_urls) || [];
        const last = urls[urls.length - 1];
        return { parse: 0, url: last ? String(last.url || '') : '' };
    }
};
