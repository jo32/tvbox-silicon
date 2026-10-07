// 立播 (csp_Libvio): a stui MacCMS site behind two anti-bot layers: a SHA-256 proof-of-work cookie
// (TS/SIG/DIFF/MODE/POW variables on the challenge page) and the funcdn jsCaptchaVerify MD5 search.
// Mirrors are discovered from publish pages (xorDecode tables). Cloud-drive shares are not ported:
// they need a Quark/UC/Xunlei login.
// ext: {"site": ["https://libviofabu.com", ...]} (also "fabu"/"publish"/"release"/"sites", or "cookie")
import { parseHTML, textOf, match, store, proofOfWork, CookieJar } from './_lite.js';

const UA = 'Mozilla/5.0 (Linux; Android 11; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
const FALLBACK = 'https://www.libhd.com';
const CHALLENGE = /browser verification|checking your browser|verify (you are|that you are) human|confirm you are human|i'?m human|proof[- ]of[- ]work|security layer|x-cdn-challenge|我是真人|浏览器验证|安全验证|人机验证/i;
const CLOUD = /夸克|UC|优视|阿里|天翼|天意|移动|迅雷|pan123|123原画|123无限|115/;

const saved = store('libvio');
let sites = [], site = '';
let jar = new CookieJar();
let funcdn = '';

const clean = value => {
    let s = String(value || '').trim();
    if (!s) return '';
    if (s.startsWith('//')) s = 'https:' + s;
    if (!/^https?:\/\//.test(s)) s = 'https://' + s;
    return s.replace(/\/+$/, '');
};
const isPublish = url => /fabu|libvio\.app|github\.io/i.test(url);
const isMirror = url => !/@|fabu|github\.io/i.test(url) && /libvio|libhd/i.test(url);
const challenged = (code, body, headers) => code === 403 || Object.keys(headers || {}).some(h => h.toLowerCase() === 'x-cdn-challenge') || CHALLENGE.test(body || '');
const absolute = (base, path) => /^https?:/.test(path) ? path : path.startsWith('//') ? 'https:' + path : base + (path.startsWith('/') ? path : '/' + path);

function headers(referer) {
    const h = { 'User-Agent': UA, Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8' };
    if (referer) h.Referer = referer;
    const cookie = cookieHeader();
    if (cookie) h.Cookie = cookie;
    return h;
}

function cookieHeader() {
    const all = new CookieJar(jar.toString());
    if (funcdn) all.add('_funcdn_token=' + funcdn);
    return all.toString();
}

/** GET following redirects by hand so cookies set on each hop are kept (curl/URLSession may not). */
function raw(url, referer) {
    let address = url, response;
    for (let hop = 0; hop < 6; hop++) {
        response = globalThis.req(address, { headers: headers(referer), timeout: 15000, redirect: false });
        jar.absorb(response.headers);
        const location = response.headers && (response.headers.location || response.headers.Location);
        if (!(response.code >= 300 && response.code < 400 && location)) break;
        address = new URL(String(Array.isArray(location) ? location[0] : location), address).href;
    }
    return { code: response.code || 0, body: typeof response.content === 'string' ? response.content : '', headers: response.headers || {} };
}

/** The proof-of-work cookie for a challenge page, or ''. */
function solve(body) {
    const vars = {};
    for (const m of String(body).matchAll(/(?:\b(?:var|let|const)\s+)?\b(TS|SIG|DIFF|MODE|POW)\s*=\s*(['"])([^'"]*)\2/gi)) vars[m[1].toUpperCase()] = m[3];
    const ok = v => /^[A-Za-z0-9_.~-]+$/.test(v || '');
    if (!('TS' in vars && 'SIG' in vars && 'DIFF' in vars) || !ok(vars.TS) || !ok(vars.SIG) || !/^[0-9a-fA-F]{0,64}$/.test(vars.DIFF)) return '';
    const mode = vars.MODE || 'auto', name = vars.POW || '__cdn_pow';
    const nonce = proofOfWork({ alg: 'sha256', prefix: vars.SIG, target: vars.DIFF.toLowerCase(), match: 'prefix', start: 0, end: 2100000, limitMs: 20000 });
    return nonce ? `${name}=${vars.TS}_${mode}_${nonce}_${vars.SIG}` : '';
}

/** Fetch with the proof-of-work retry (as the spider's S()). */
function page(url, referer) {
    let response = raw(url, referer);
    if (!challenged(response.code, response.body, response.headers)) return response;
    const cookie = solve(response.body);
    if (!cookie) return response;
    jar.add(cookie);
    response = raw(url, referer);
    jar.remove(cookie.slice(0, cookie.indexOf('=')));
    persist();
    return response;
}

/** funcdn jsCaptchaVerify: brute-force the MD5 answer and exchange it for an fc_token. */
function funcdnToken(body) {
    const challenge = match("challenge:\\s*'([^']*)'", body), answer = match("answer:\\s*'([^']*)'", body);
    if (!challenge || !answer) return '';
    const code = proofOfWork({ alg: 'md5', prefix: challenge, target: answer, match: 'equal', start: 100000, end: 999999, limitMs: 20000 });
    if (!code) return '';
    const form = { userinfo: match("userinfo:\\s*'([^']*)'", body), hostinfo: match("hostinfo:\\s*'([^']*)'", body), challenge, answer, code };
    const response = globalThis.req('https://fn-captcha.tacool.com/jsCaptchaVerify', { method: 'POST', data: form });
    try { return String(JSON.parse(response.content).fc_token || ''); } catch { return ''; }
}

/** GET a site path, trying the current mirror first, then the others (as the spider's t()/u()). */
function get(path, referer) {
    const candidates = [...new Set([site, ...sites].filter(Boolean))];
    let last = { code: 0, body: '', headers: {} };
    for (const base of /^https?:/.test(path) ? [''] : candidates) {
        const url = base ? absolute(base, path) : path;
        let response = page(url, referer || (base ? base + '/' : ''));
        if (response.body.includes('jsCaptchaVerify') && response.body.includes('_funcdn_token')) {
            const token = funcdnToken(response.body);
            if (token) { funcdn = token; response = page(url, referer || (base ? base + '/' : '')); }
        }
        if (response.code >= 200 && response.code < 400 && response.body && !challenged(response.code, response.body, response.headers)) {
            if (base) { site = base; saved.set('site', site); }
            return response.body;
        }
        last = response;
    }
    if (challenged(last.code, last.body, last.headers)) throw new Error('站点要求完成浏览器验证');
    return last.body;
}

function persist() { saved.set('cookie', jar.toString()); }

/** Mirrors listed on a publish page (xorDecode('n,n,...', _K) entries, then plain URLs). */
function mirrorsFrom(body) {
    const found = [];
    if (!body.includes('xorDecode') || !body.includes('_OFFICIAL') || !body.includes('_BACKUP')) return found;
    const key = match("const\\s+_K\\s*=\\s*['\"]([^'\"]+)", body);
    if (key) {
        const backup = match('const\\s+_BACKUP\\s*=\\s*\\[(.*?)\\];', body) || body;
        for (const m of backup.matchAll(/xorDecode\(['"]([0-9,\s]+)['"]\s*,\s*_K\)/g)) {
            const url = clean(m[1].split(',').map((n, i) => String.fromCharCode(parseInt(n.trim(), 10) ^ key.charCodeAt(i % key.length))).join(''));
            if (isMirror(url) && !found.includes(url)) found.push(url);
        }
    }
    for (const m of body.matchAll(/https?:\/\/[^\s"'<>]+/g)) { const url = clean(m[0]); if (isMirror(url) && !found.includes(url)) found.push(url); }
    return found;
}

function discover(entries) {
    const publish = [], direct = [];
    for (const entry of entries) { const url = clean(entry); if (url) (isPublish(url) ? publish : direct).push(url); }
    for (const url of publish) {
        const response = page(url + '/', url + '/');
        if (!challenged(response.code, response.body, response.headers)) {
            const mirrors = mirrorsFrom(response.body);
            if (mirrors.length) return mirrors;
        }
    }
    return direct;
}

function videos(body) {
    const $ = parseHTML(body);
    const list = [], seen = new Set();
    $('a.stui-vodlist__thumb[href*="/detail/"], ul.stui-vodlist a[title][href*="/detail/"], a[href*="/detail/"][title]').each((_, a) => {
        const node = $(a);
        const id = (match('/detail/([^/?#]+)', node.attr('href') || '') || '').replace('.html', '');
        const name = (node.attr('title') || '').trim() || textOf(node);
        if (!id || !name || seen.has(id)) return;
        seen.add(id);
        const img = node.find('img').first();
        const pic = node.attr('data-original') || node.attr('data-src') || node.attr('src') || match("url\\(['\"]?([^'\")]+)", node.attr('style') || '')
            || img.attr('data-original') || img.attr('data-src') || img.attr('src') || match("url\\(['\"]?([^'\")]+)", img.attr('style') || '') || '';
        list.push({ vod_id: id, vod_name: name, vod_pic: pic ? (pic.startsWith('data:') ? pic : absolute(site || FALLBACK, pic)) : '' });
    });
    return list;
}

export default {
    init(ext) {
        let config = ext;
        if (typeof config === 'string') { try { config = JSON.parse(config); } catch { config = { site: config }; } }
        config = config || {};
        jar = new CookieJar(saved.get('cookie'));
        const supplied = config.cookie || config.libvio_cookie || config.browser_cookie || config.verify_cookie || (config.headers || config.header || {}).Cookie;
        if (supplied) jar.add(supplied);
        const entries = [];
        for (const key of ['site', 'fabu', 'publish', 'release', 'sites']) {
            const value = config[key];
            if (Array.isArray(value)) entries.push(...value); else if (value) entries.push(value);
        }
        sites = discover(entries.length ? entries : [FALLBACK]);
        if (!sites.length) sites = [FALLBACK];
        const remembered = saved.get('site');
        site = remembered && sites.includes(remembered) ? remembered : sites[0];
    },
    home() {
        const body = get('');
        const $ = parseHTML(body);
        const classes = [], seen = new Set();
        $('ul.stui-header__menu > li > a[href^="/type/"], a[href^="/show/"]').each((_, a) => {
            const name = textOf($(a));
            const id = ($(a).attr('href') || '').replace('.html', '').replace(/^\//, '');
            if (name && name !== '更多' && !seen.has(id)) { seen.add(id); classes.push({ type_id: id, type_name: name }); }
        });
        return { class: classes, list: videos(body) };
    },
    category(tid, pg) {
        let path = String(tid || '').trim().replace(/^\//, '').replace(/\.html$/, '');
        const show = path.startsWith('show/') ? match('show/(\\d+)', path) : '';
        path = show ? `show/${show}--------${pg}---.html` : `${path}-${pg}.html`;
        const body = get(path);
        const list = videos(body);
        const $ = parseHTML(body);
        const current = parseInt(pg, 10);
        const pager = textOf($('ul.stui-page__item li.active.num a').first()) || textOf($('ul.stui-page__item li.active.num').first());
        let total = pager.includes('/') ? parseInt(pager.split('/')[1], 10) || 0 : 0;
        if (total <= 0) total = current + 1;
        return { page: current, pagecount: total, limit: list.length, total: list.length * total, list };
    },
    detail(id) {
        const $ = parseHTML(get(`detail/${id}.html`));
        const meta = $('div.vod-info div.vod-meta');
        const items = meta.first().find('span.meta-item');
        const item = i => items.length > i ? textOf(items.eq(i)).replace(/\//g, '').trim() : '';
        const line = (i, label) => { if (meta.length <= i) return ''; const t = textOf(meta.eq(i)); return t.startsWith(label) ? t.slice(label.length).trim() : t; };
        const froms = [], urls = [];
        $('div.playlist-panel').each((_, panel) => {
            const p = $(panel);
            if (p.hasClass('netdisk-panel')) return;
            const title = textOf(p.find('h3'));
            if (!title) return;
            const episodes = [];
            p.find('a[href*="/play/"], a[href*="/w/"]').each((__, a) => {
                const playId = (match('/(?:play|w)/([^/?#]+)', $(a).attr('href') || '') || '').replace('.html', '');
                const name = textOf($(a));
                if (playId && name) episodes.push(`${name}$${playId}`);
            });
            if (episodes.length) { froms.push(title); urls.push(episodes.join('#')); }
        });
        const poster = $('div.vod-poster img').first();
        const pic = poster.attr('data-original') || poster.attr('src') || '';
        return { list: [{
            vod_id: id, vod_name: textOf($('div.vod-info h1.title')), vod_pic: pic ? absolute(site, pic) : '',
            type_name: item(0), vod_area: item(1), vod_year: item(2), vod_actor: line(1, '主演：'), vod_director: line(2, '导演：'),
            vod_remarks: textOf($('div.vod-info .vod-rating .score').first()).replace('分', ''),
            vod_content: textOf($('div.vod-info span.detail-content, div.vod-info p').first()).replace('展开 ▾', '').replace('展开', '').trim(),
            vod_play_from: froms.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search(wd) {
        return { list: videos(get('search/-------------.html?wd=' + encodeURIComponent(wd))) };
    },
    play(flag, id) {
        if (CLOUD.test(flag || '')) return { parse: 0, url: '', msg: '网盘线路需要登录' };
        let path = String(id || '').trim();
        if (!path.startsWith('http')) {
            path = path.replace(/^\//, '');
            if (!path.startsWith('play/') && !path.startsWith('w/')) path = 'w/' + path;
            if (!path.endsWith('.html')) path += '.html';
        }
        const pageUrl = path.startsWith('http') ? path : absolute(site, path);
        const body = get(path, pageUrl);
        const json = match('(?:var\\s+)?player_aaaa\\s*=\\s*(\\{.*?\\})\\s*;?\\s*</script>', body);
        if (!json) return { parse: 0, url: '', msg: '解析失败' };
        const player = JSON.parse(json);
        let url = String(player.url || '');
        if (Number(player.encrypt) === 2) url = decodeURIComponent(Buffer.from(url, 'base64').toString('latin1'));
        else if (Number(player.encrypt) === 1) url = decodeURIComponent(url);
        if (!url) return { parse: 0, url: '', msg: '解析失败' };
        const result = { parse: 0, url, header: headers(pageUrl) };
        if (url.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
