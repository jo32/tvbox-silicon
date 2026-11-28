// GenericHTML (csp_GenericHTML): a configuration-driven spider for HTML sites.
// The viewer adds one source in a subscription with `type: 3`, `api: "csp_GenericHTML"` and a JSON `ext`
// describing how to read the site with CSS selectors. No per-site JavaScript or JAR is needed.
//
// ext example (a single line of JSON; CSS selectors are the whole contract):
// {
//   "url": "https://www.example.com",
//   "encoding": "utf-8",
//   "header": { "User-Agent": "Mozilla/5.0 ...", "Referer": "@base" },
//   "class":  { "selector": ".nav a", "id": { "attr": "href", "regex": "/list/([^.]+)\\.html" }, "name": {} },
//   "list":   { "selector": ".item",
//               "fields": { "vod_id": { "attr": "href", "regex": "/play/([^.]+)\\.html" },
//                           "vod_name": { "selector": "h3 a" },
//                           "vod_pic": { "selector": "img", "attr": "src" },
//                           "vod_remarks": { "selector": ".note" } } },
//   "detailUrl": "/play/{id}.html",
//   "detail": { "fields": { "vod_name": { "selector": "h1" },
//                           "vod_content": { "selector": ".desc" } },
//               "playFrom": { "selector": ".line .title" },
//               "playUrl":  { "selector": ".line a", "attr": "href" } },
//   "play":   { "url": { "selector": "video source", "attr": "src" } },
//   "search": { "url": "/search?wd={wd}" }
// }
//
// Field rule forms:
//   "selector"                       -> trimmed text of the first match
//   { "selector": "...",             -> scope inside each item (defaults to the item itself)
//     "attr": "href",                -> read an attribute instead of text
//     "html": true,                  -> read inner HTML instead of text
//     "index": 1,                    -> take the Nth match (negative counts from the end)
//     "join": ", ",                  -> concatenate all matches with this separator
//     "regex": "group(1)",           -> apply a regex and take capture group 1
//     "tpl": "/play/{v}.html",       -> substitute the value into a URL template
//     "base": true,                  -> resolve the value as an absolute URL against the site
//     "default": "未知"              -> fallback when no value was found
//   }
// URL templates use {base}, {id}, {wd}, {pg} and {v} (a field value).

import { parseHTML, textOf, absolute } from './_lite.js';

const DEFAULT_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

let cfg = {};
let base = '';
let routes = {};

function configFrom(ext) {
    if (!ext) throw new Error('通用 HTML 源缺少配置 (ext)');
    if (typeof ext === 'string') {
        const text = ext.trim();
        if (!text.startsWith('{')) throw new Error('通用 HTML 源的 ext 应为 JSON 配置');
        return JSON.parse(text);
    }
    return ext;
}

/** Build request headers, expanding `@base` placeholders in configured values. */
function headers(mobile = false, extra = null) {
    const out = { 'User-Agent': DEFAULT_UA };
    const custom = cfg.header || cfg.headers || {};
    for (const [key, value] of Object.entries(custom)) {
        out[key] = String(value).replace(/@base/g, base + '/');
    }
    if (mobile) out['User-Agent'] = MOBILE_UA;
    if (!out['Referer']) out['Referer'] = base + '/';
    for (const [key, value] of Object.entries(extra || {})) {
        out[key] = String(value).replace(/@base/g, base + '/');
    }
    return out;
}

function get(url, mobile = false, extraHeaders = null) {
    if (!url) return '';
    try {
        const response = globalThis.req(url, { headers: headers(mobile, extraHeaders), encoding: cfg.encoding || 'utf-8', timeout: 20000 });
        return response && response.content ? String(response.content) : '';
    } catch {
        return '';
    }
}

/** Resolve an address against the site, honouring an explicit {base} template. */
function url(value) {
    const text = String(value || '').trim();
    if (!text) return '';
    return absolute(base, text.replace(/\{base\}/g, base));
}

/** Fill a template such as "/play/{id}.html" or "/list/{id}-{pg}.html". */
function fill(template, values) {
    return String(template || '').replace(/\{(base|id|wd|v|pg)\}/g, (_, key) =>
        key === 'base' ? base : String(values[key] ?? ''));
}

/** Apply a configured regex, taking capture group 1 when present. */
function applyRegex(value, pattern) {
    if (!pattern) return String(value || '').trim();
    try {
        const match = new RegExp(pattern).exec(String(value || ''));
        return match ? String(match[1] ?? match[0] ?? '').trim() : '';
    } catch { return ''; }
}

/** Extract one value from a cheerio scope using a rule (string selector or object). */
function pick($, scope, rule, values = {}) {
    if (rule == null) return '';
    const spec = typeof rule === 'string' ? { selector: rule } : rule;
    let nodes = spec.selector
        ? (scope && scope.find ? scope.find(spec.selector) : $(spec.selector))
        : (scope && scope.length ? scope : $());

    if (spec.index != null) {
        const raw = Number(spec.index) || 0;
        const i = raw < 0 ? Math.max(0, nodes.length + raw) : raw;
        nodes = nodes.eq(i);
    }

    const read = node => {
        const el = $(node);
        const text = spec.html ? String(el.html() || '') : spec.attr ? String(el.attr(spec.attr) || '').trim() : textOf(el);
        return applyRegex(text, spec.regex);
    };

    let value = '';
    if (spec.join != null) {
        value = nodes.toArray().map(read).filter(Boolean).join(spec.join === true ? ', ' : String(spec.join));
    } else if (nodes.length) {
        value = read(nodes.eq(0));
    }

    if (spec.tpl) value = fill(spec.tpl, { ...values, v: value });
    if (spec.base) value = url(value);
    if (!value && spec.default != null) value = String(spec.default);
    return value;
}

/** Map a cheerio selection of item nodes into TVBox video objects. */
function items($, selector, fields, limit = Infinity) {
    const out = [], seen = new Set();
    if (!selector) return out;
    $(selector).each((_, el) => {
        if (out.length >= limit) return;
        const scope = $(el);
        const video = {};
        for (const [key, rule] of Object.entries(fields || {})) {
            video[key] = pick($, scope, rule, video);
        }
        // Normalize an id that came back as an absolute detail link.
        if (video.vod_id && !/^https?:/i.test(video.vod_id)) video.vod_id = url(video.vod_id);
        if (!video.vod_id || seen.has(video.vod_id)) return;
        if (!video.vod_name) video.vod_name = textOf(scope);
        if (!video.vod_name) return;
        seen.add(video.vod_id);
        out.push(video);
    });
    return out;
}

function detailURL(id) {
    if (/^https?:/i.test(id)) return id;
    if (cfg.detailUrl) return url(fill(cfg.detailUrl, { id }));
    return url(id);
}

function categoryURL(tid, pg) {
    const template = cfg.categoryUrl || '/list/{id}-{pg}.html';
    return url(fill(template, { id: tid, pg: pg > 1 ? pg : 1, v: tid }));
}

function searchURL(wd, pg) {
    const template = (cfg.search && cfg.search.url) || '/search?wd={wd}';
    return url(fill(template, { wd: encodeURIComponent(wd), pg: pg > 1 ? pg : 1, v: wd }));
}

/** Parse a list page; `listCfg` lets search/category override the default list selectors. */
function page(html, pg, listCfg) {
    const $ = parseHTML(html);
    const lc = listCfg || cfg.list || {};
    const limit = Number(lc.limit) > 0 ? Number(lc.limit) : Infinity;
    const list = items($, lc.selector, lc.fields, limit);
    const lastRule = lc.lastPage || (cfg.list && cfg.list.lastPage);
    const last = lastRule ? pick($, null, lastRule) : '';
    const pagecount = Math.max(1, Number(last) || (list.length ? pg : 1));
    return { page: pg, pagecount, limit: lc.pageSize ? Number(lc.pageSize) || 20 : 20, total: list.length, list };
}

export default {
    init(ext) {
        cfg = configFrom(ext);
        base = String(cfg.url || cfg.base || '').trim().replace(/\/+$/, '');
        if (!/^https?:\/\//i.test(base)) throw new Error('通用 HTML 源需要以 http(s) 开头的 url');
        routes = {};
    },

    home() {
        const html = get(base + '/');
        const $ = parseHTML(html);
        const classes = [];
        if (cfg.class && cfg.class.selector) {
            $(cfg.class.selector).each((_, el) => {
                const scope = $(el);
                const id = pick($, scope, cfg.class.id);
                const name = pick($, scope, cfg.class.name || {});
                if (id && name) classes.push({ type_id: id, type_name: name });
            });
        }
        return { class: classes, ...page(html, 1) };
    },

    category(tid, pg) {
        const p = Math.max(1, Number(pg) || 1);
        const listCfg = (cfg.category && cfg.category.list) || cfg.list;
        return page(get(categoryURL(tid, p)), p, listCfg);
    },

    detail(id) {
        const html = get(detailURL(id));
        const $ = parseHTML(html);
        const fields = (cfg.detail && cfg.detail.fields) || {};
        const video = {};
        for (const [key, rule] of Object.entries(fields)) video[key] = pick($, null, rule, video);
        video.vod_id = id;
        if (!video.vod_name) video.vod_name = textOf($('title'));

        const groups = [];
        const d = cfg.detail || {};
        const flags = [];
        const urls = [];
        if (d.playFrom && d.playUrl) {
            if (d.playFrom.selector || typeof d.playFrom === 'string') {
                $(typeof d.playFrom === 'string' ? d.playFrom : d.playFrom.selector).each((_, el) =>
                    flags.push(applyRegex(textOf($(el)), d.playFrom.regex)));
            } else {
                flags.push(pick($, null, d.playFrom) || '播放');
            }
            $(d.playUrl.selector || d.playUrl).each((_, el) => {
                const scope = $(el);
                let href = d.playUrl.attr ? String(scope.attr(d.playUrl.attr) || '') : textOf(scope);
                href = applyRegex(href, d.playUrl.regex);
                urls.push(url(href));
            });
            const names = flags.length ? flags : ['播放'];
            groups.push(names.join('$$$'), urls.filter(Boolean).join('#'));
            // Remember the first URL of each line so play(flag, id) can fall back to it.
            routes = {};
            names.forEach((name, i) => { if (urls[i] && name) routes[name] = urls[i]; });
        }
        video.vod_play_from = groups[0] || cfg.playFrom || '播放';
        video.vod_play_url = groups[1] || url(id);
        return { list: [video] };
    },

    search(wd, pg) {
        const p = Math.max(1, Number(pg) || 1);
        const listCfg = (cfg.search && cfg.search.list) || cfg.list;
        return page(get(searchURL(wd, p)), p, listCfg);
    },

    play(flag, id) {
        const rule = (cfg.play && cfg.play.url) || {};
        const extra = (cfg.play && cfg.play.header) || null;
        const html = get(detailURL(id), true, extra);
        const $ = parseHTML(html);
        const address = pick($, null, rule);
        return { parse: 0, url: url(address || routes[flag] || id), header: headers(true, extra) };
    }
};
