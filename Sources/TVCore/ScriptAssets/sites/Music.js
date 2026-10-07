// 易听音乐 (fty csp_MusicGuard): 4c44.com music pages. Pages may first ask for a human check (POST csrf_token +
// human_check=on, then the session cookie). Songs play through /js/play.php with key = yyyyMMddHHmm + "4c44";
// MV entries play through down.php. The JAR's search asks for input in a dialog; the port searches /so/<word>.html.
import { parseHTML, textOf, CookieJar, formBody } from './_lite.js';

const HOST = 'http://www.4c44.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36';
const COVER = 'https://img07.sogoucdn.com/v2/thumb/retype_exclude_gif/ext/auto/q/95/crop/xy/ai/t/0/?appid=122&url=https://s1.imagehub.cc/images/2026/03/01/9991fceaab9b26082b523d691e3616f5.md.jpg';
const LISTS = ['div.lksinger_list > ul > li', 'div.singer_list > ul > li', 'div.video_list > ul > li', '.ilingku_fl > li'];

const jar = new CookieJar();
function request(url, options = {}) {
    const headers = { 'User-Agent': UA, Referer: HOST, Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', ...(options.headers || {}) };
    const cookie = jar.toString();
    if (cookie) headers.Cookie = cookie;
    const response = globalThis.req(url, { ...options, headers, timeout: 15000 });
    jar.absorb(response.headers);
    return String(response.content || '');
}
// GET a page, passing the human check once if the site asks for it.
function page(url) {
    let html = request(url);
    const token = (html.match(/name=["']csrf_token["'][^>]*value=["']([^"']+)/) || html.match(/value=["']([^"']+)["'][^>]*name=["']csrf_token/) || [])[1];
    if (token && html.includes('human_check')) {
        request(url, { method: 'POST', body: formBody({ csrf_token: token, human_check: 'on' }), headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
        html = request(url);
    }
    return parseHTML(html);
}
function cards($) {
    for (const selector of LISTS) {
        const items = $(selector);
        if (!items.length) continue;
        return items.toArray().map(el => {
            const item = $(el);
            const a = item.find('.name a').first().length ? item.find('.name a').first() : item.find('a').first();
            const name = textOf(a) || a.attr('title') || '';
            const img = item.find('img').first();
            return name ? { vod_id: a.attr('href') || '', vod_name: name, vod_pic: img.attr('data-original') || img.attr('src') || COVER } : null;
        }).filter(v => v && v.vod_id && v.vod_name !== '那些好听到发疯的网络歌 一秒沦陷');
    }
    return [];
}
const stamp = () => { const d = new Date(Date.now() + 8 * 3600 * 1000), p = n => String(n).padStart(2, '0'); return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}`; };

export default {
    home() {
        const $ = page(HOST);
        const classes = $('div.pull-right > div > ul > li > a').toArray().map(a => ({ type_id: ($(a).attr('href') || '').replace('.html', ''), type_name: $(a).attr('title') || textOf($(a)) })).filter(c => c.type_id && c.type_name);
        return { class: classes, list: cards($) };
    },
    category(tid, pg) {
        const p = parseInt(pg, 10) || 1;
        return { page: p, list: cards(page(`${HOST}${tid}/${p}.html`)) };
    },
    detail(id) {
        const $ = page(HOST + id);
        const name = textOf($('.play_list h1').first()).split(',')[0];
        const songs = [];
        let pic = '';
        $('.play_list > ul > li').each((_, el) => {
            const item = $(el);
            const a = item.find('.name a').first();
            const href = a.attr('href') || '';
            if (!href) return;
            const title = textOf(a);
            songs.push(`${title}$${href}`);
            if (item.find('.mv').length) songs.push(`${title}-MTV$${item.find('.mv a').first().attr('href') || ''}`);
            if (!pic) { try { pic = page(HOST + href)('div.play_left img').first().attr('src') || ''; } catch {} }
        });
        return { list: [{ vod_id: id, vod_name: name, vod_pic: pic || COVER, vod_actor: '易听', vod_director: '易听', vod_play_from: '易听', vod_play_url: songs.join('#') }] };
    },
    search(wd) {
        return { list: cards(page(`${HOST}/so/${encodeURIComponent(wd)}.html`)) };
    },
    play(flag, path) {
        const id = String(path).slice(String(path).lastIndexOf('/') + 1).replace(/\.html$/, '');
        if (String(path).includes('mp4')) return { parse: 0, url: `${HOST}/data/down.php?ac=vplay&id=${id}&q=1080` };
        let music = id;
        if (String(path).includes('radio')) music = (request(HOST + path).match(/"music","(.*?)"/) || [])[1] || id;
        const data = JSON.parse(request(`${HOST}/js/play.php`, { method: 'POST', body: formBody({ id: music, type: 'music', key: stamp() + '4c44' }), headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest' } }) || '{}');
        return { parse: 0, url: String(data.url || ''), header: { 'User-Agent': UA } };
    }
};
