// 厂长资源 (csp_CZ): a WordPress video site. Play pages carry an AES-CBC encrypted player config (dncry);
// otherwise the player iframe's url= parameter, `mysvg`, or reversed-base64 `result_v2` is used.
// Optional login: ext {"cookie": ..., "username": ..., "password": ..., "site": [...]}.
import { parseHTML, textOf, match, aesDecrypt, store, CookieJar } from './_lite.js';

const UA = 'Mozilla/5.0 (Linux; Android 15; PJZ110 Build/AP3A.240617.008; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.127 Mobile Safari/537.36';
const IFRAME_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.75 Safari/537.36';
const CATEGORIES = [['/dbtop250', '豆瓣Top250'], ['/movie_bt', '分类筛选'], ['/meijutt', '美剧'], ['/riju', '日剧'], ['/hanjutv', '韩剧'], ['/fanju', '番剧'], ['/gcj', '国产剧'],
    ['/dongmanjuchangban', '剧场版'], ['/haiwaijuqita', '海外剧'], ['/gaofenyingshi', '高分影视'], ['/huayudianying', '华语电影'], ['/oumeidianying', '欧美电影'], ['/hanguodianying', '韩国电影'], ['/ribendianying', '日本电影']];

const saved = store('cz');
let site = 'https://www.4kcz.com';
let jar = new CookieJar();
let username = '', password = '';
let warmed = false, triedLogin = false;

const headers = extra => ({ 'User-Agent': UA, Referer: site + '/', 'Accept-Language': 'zh-CN,zh;q=0.9', Cookie: jar.toString(), ...extra });

function raw(url, extra) {
    let address = url, response;
    for (let hop = 0; hop < 6; hop++) {
        response = globalThis.req(address, { headers: headers(extra), redirect: false, timeout: 15000 });
        jar.absorb(response.headers);
        const location = response.headers && (response.headers.location || response.headers.Location);
        if (!(response.code >= 300 && response.code < 400 && location)) break;
        address = new URL(String(location), address).href;
    }
    return response.content || '';
}

function login(home) {
    const nonce = match('wpnonce[^a-f0-9]{0,16}([a-f0-9]{8,})', home, 'i');
    const extra = nonce ? { 'X-WP-Nonce': nonce } : {};
    const form = { username, password, email: '', url: site + '/', invitecode: '', linuser: '' };
    try {
        const response = globalThis.req(site + '/api/vs/session', { method: 'POST', data: form, headers: headers(extra) });
        jar.absorb(response.headers);
        if (/wordpress_logged_in_|wordpress_sec_/.test(jar.toString())) saved.set('cookie', jar.toString());
    } catch { /* stay anonymous */ }
}

/** Fetch a page; warm the session on first use and log in when the page asks for it. */
function page(url) {
    if (!warmed) { warmed = true; const home = raw(site + '/'); if (username && password && !triedLogin) { triedLogin = true; login(home); } }
    const body = raw(url);
    if (body.includes('登录后即可观看') && username && password) {
        login(raw(site + '/'));
        return raw(url);
    }
    return body;
}

function cards(body) {
    const $ = parseHTML(body);
    const list = [];
    $('ul > li').each((_, li) => {
        const a = $(li).find('h3 a').first();
        const href = a.attr('href') || '', name = textOf(a);
        if (!href || !name) return;
        const img = $(li).find('img').first();
        list.push({ vod_id: href, vod_name: name, vod_pic: img.attr('data-original') || img.attr('src') || '', vod_remarks: textOf($(li).find('.pic-text').first()) });
    });
    return list;
}

const numbered = counts => name => { const n = (counts.get(name) || 0) + 1; counts.set(name, n); return n === 1 ? name : `${name}-${n}`; };

function queryUrl(address) {
    const at = address.indexOf('?');
    if (at < 0) return '';
    for (const pair of address.slice(at + 1).split('&')) {
        const eq = pair.indexOf('=');
        if (decodeURIComponent(eq >= 0 ? pair.slice(0, eq) : pair) === 'url') return decodeURIComponent((eq >= 0 ? pair.slice(eq + 1) : '').replace(/&amp;/g, '&'));
    }
    return '';
}

export default {
    init(ext) {
        let config = {};
        try { config = typeof ext === 'string' ? JSON.parse(ext || '{}') : (ext || {}); } catch { config = { site: ext }; }
        const sites = (Array.isArray(config.site) ? config.site : [config.site]).filter(Boolean).map(s => (/^https?:\/\//.test(s) ? s : 'https://' + s).replace(/\/+$/, ''));
        username = String(config.username || '').trim(); password = String(config.password || '');
        jar = new CookieJar(saved.get('cookie') || config.cookie || '');
        warmed = false; triedLogin = false;
        for (const candidate of sites) {
            try {
                const code = globalThis.req(candidate, { method: 'HEAD', timeout: 5000, headers: { 'User-Agent': UA } }).code;
                if (code >= 200 && code < 400) { site = candidate; return; }
            } catch { /* next */ }
        }
        if (sites.length) site = sites[0];
    },
    home() {
        return { class: CATEGORIES.map(([type_id, type_name]) => ({ type_id, type_name })), list: cards(page(site)) };
    },
    category(tid, pg) {
        return { list: cards(page(pg === '1' ? site + tid : `${site}${tid}/page/${pg}`)) };
    },
    detail(id) {
        const address = id.startsWith('http') ? id : site + id;
        const $ = parseHTML(page(address));
        const item = { vod_id: id, vod_name: textOf($('h1').first()) };
        const img = $('.dyimg img').first().length ? $('.dyimg img').first() : $('article img').first();
        if (img.length) item.vod_pic = img.attr('data-original') || img.attr('src') || '';
        let intro = $('.yp_context').first();
        if (!intro.length) { const label = $('div').filter((_, d) => textOf($(d)).includes('电影介绍')).last(); intro = label.next(); }
        if (intro.length) item.vod_content = textOf(intro);
        const groups = [];
        $('.paly_list_btn').each((_, g) => { const links = $(g).find('a[href*=v_play]').toArray(); if (links.length) groups.push(links); });
        if (!groups.length) {
            let links = $('.doulist-item a[href*=v_play]').toArray();
            if (!links.length) links = $('a[href*=v_play]').toArray();
            if (links.length) groups.push(links);
        }
        const seen = new Set(), counts = new Map(), label = numbered(counts);
        const froms = [], urls = [];
        for (const group of groups) {
            const names = [], hrefs = [];
            for (const a of group) {
                const href = ($(a).attr('href') || '').trim();
                if (!href || seen.has(href)) continue;
                seen.add(href); names.push(textOf($(a)) || '播放'); hrefs.push(href);
            }
            if (!hrefs.length) continue;
            if (names.some(n => /线路|^line/.test(n.replace(/\s+/g, '').toLowerCase()))) {
                hrefs.forEach((href, i) => { froms.push(label(names[i])); urls.push('正片$' + href); });
            } else {
                const episodeCounts = new Map(), episode = numbered(episodeCounts);
                froms.push(label('厂长资源'));
                urls.push(hrefs.map((href, i) => `${episode(names[i])}$${href}`).join('#'));
            }
        }
        item.vod_play_from = froms.join('$$$');
        item.vod_play_url = urls.join('$$$');
        return { list: [item] };
    },
    search(wd) {
        return { list: cards(page(`${site}/boss1O1?q=${encodeURIComponent(wd)}`)) };
    },
    play(flag, id) {
        const address = id.startsWith('http') ? id : site + id;
        const body = page(address);
        if (body.includes('登录后即可观看')) return { parse: 1, url: address, msg: '需要登录' };
        let url = '', subtitle = '';
        const config = /"([^"]+)";var [\d\w]+=function dncry.*md5.enc.Utf8.parse\("([\d\w]+)".*md5.enc.Utf8.parse\((\d+)\)/.exec(body);
        if (config) {
            let plain = '';
            try { plain = aesDecrypt(config[1], config[2], config[3].padStart(16, '0')); } catch { plain = ''; }
            url = match('video: \\{url: "([^"]+)"', plain);
            subtitle = match('subtitle: \\{url:"([^"]+\\.vtt)"', plain);
        }
        if (!url) {
            const $ = parseHTML(body);
            let frame = $('div.videoplay > iframe').first().attr('src') || '';
            if (frame) {
                frame = frame.startsWith('//') ? 'https:' + frame : frame.startsWith('http') ? frame : site + (frame.startsWith('/') ? '' : '/') + frame;
                url = queryUrl(frame);
                if (!url.startsWith('http')) url = '';
                if (!url) {
                    const inner = globalThis.req(frame, { headers: { 'User-Agent': IFRAME_UA, 'Upgrade-Insecure-Requests': '1', 'Sec-Fetch-Dest': 'iframe', Referer: site, 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Mode': 'navigate', Cookie: jar.toString() } }).content || '';
                    url = match("const\\s+mysvg\\s*=\\s*['\"]([^'\"]+)['\"]", inner);
                    const v2 = match('var result_v2 = (\\{.*?\\});', inner);
                    if (!url && v2) { try { url = Buffer.from(String(JSON.parse(v2).data).split('').reverse().join(''), 'base64').toString('utf8'); } catch { url = ''; } }
                }
            }
        }
        if (!url) return { parse: 1, url: address };
        const result = { parse: 0, playUrl: '', url, header: { 'User-Agent': UA, Origin: site } };
        if (subtitle) { result.subf = '/vtt/utf-8'; result.subt = subtitle; }
        return result;
    }
};
