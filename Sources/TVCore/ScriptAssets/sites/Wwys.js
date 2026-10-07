// 糯米影视 (csp_Wwys): a MacCMS v8 site scraped as HTML. Episodes come from the play page's
// `mac_url`; playback follows the site's player iframe chain to the stream address.
import { parseHTML, textOf, firstText, firstAttr, match, lastNumber, absolute, http } from './_lite.js';

const UA = 'Mozilla/5.0 (Linux; Android 13; SM-A037U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36  uacq';
const FILTERS = {
    1: [{ key: 'cateId', name: '类型', value: [['全部', '1'], ['动作片', '5'], ['喜剧片', '6'], ['爱情片', '7'], ['科幻片', '8'], ['恐怖片', '9'], ['剧情片', '10'], ['战争片', '11'], ['惊悚片', '16'], ['奇幻片', '17']].map(([n, v]) => ({ n, v })) }],
    2: [{ key: 'cateId', name: '类型', value: [['全部', '2'], ['国产剧', '12'], ['港台剧', '13'], ['日韩剧', '14'], ['欧美剧', '15']].map(([n, v]) => ({ n, v })) }]
};

let site = 'https://vip.wwgz.cn:5200';
const headers = () => ({ 'User-Agent': UA, Referer: site + '/' });
const url = path => absolute(site, path);

function get(address) {
    try { return http(address, { headers: headers() }).content || ''; } catch { return ''; }
}

function card($, li, seen, out) {
    const id = lastNumber(firstAttr($, li, 'a[href]', 'href'));
    let name = firstAttr($, li, 'a[title]', 'title') || firstText($, li, 'a[title]') || firstText($, li, 'h3 a, h4 a, .title a, a[href]');
    if (!id || !name || seen.has(id)) return;
    seen.add(id);
    out.push({ vod_id: id, vod_name: name, vod_pic: url(firstAttr($, li, 'img', 'data-src', 'data-original', 'src')), vod_remarks: firstText($, li, '.s1, .pic-text, .remarks, .continu, span') });
}

function cards($) {
    let items = $('.resize_list > li');
    if (!items.length) items = $('ul.resize_list li, .vodlist li, .list li, li:has(a[href*=vod-detail-id])');
    const seen = new Set(), out = [];
    items.each((_, li) => card($, li, seen, out));
    return out;
}

function info($, label) {
    let found = '';
    $('.vodinfobox li, .info li, .vod_content li, p').each((_, el) => {
        const value = textOf($(el));
        if (!found && value.startsWith(label)) { found = value.slice(label.length).replace(/^\s*[:：]?\s*/, '').trim(); }
    });
    return found;
}

const playerPrefix = script => match(`(?:src\\s*=\\s*)?["']([^"']+)["']\\s*\\+\\s*videoUrl`, script) || match(`src\\s*=\\s*["']([^"']+)`, script);
const prefixed = (prefix, id) => prefix ? url(prefix) + id : '';

export default {
    init(ext) {
        let value = String(ext || '').trim();
        if (value && !value.startsWith('http')) { try { value = JSON.parse(value).site || ''; } catch { value = ''; } }
        if (value.startsWith('http')) site = value.replace(/\/+$/, '');
    },
    home() {
        const $ = parseHTML(get(site));
        const classes = [], seen = new Set();
        $('#topnav > ul:nth-child(1) li a, #topnav li a').each((_, a) => {
            const href = $(a).attr('href') || '';
            const id = href.split('-')[3] || lastNumber(href);
            const name = textOf($(a));
            if (id && name && !seen.has(id)) { seen.add(id); classes.push({ type_id: id, type_name: name }); }
        });
        if (!classes.length) classes.push(...[['1', '电影'], ['2', '电视剧'], ['3', '综艺'], ['4', '动漫']].map(([type_id, type_name]) => ({ type_id, type_name })));
        let list = [];
        const blocks = $('section.mod:nth-child(3) > div:nth-child(2) ul.resize_list');
        if (blocks.length) { const seenVideo = new Set(); blocks.find('li').each((_, li) => card($, li, seenVideo, list)); }
        if (!list.length) list = cards($);
        return { class: classes, list, filters: FILTERS };
    },
    category(tid, pg, filter, extend = {}) {
        const id = extend.cateId || tid;
        const list = cards(parseHTML(get(`${site}/vod-list-id-${id}-pg-${pg}-order--by-time-class-0-year-0-letter--area--lang-.html`)));
        const page = Number(pg);
        return { list, page, pagecount: page + 1, limit: list.length, total: Math.max(list.length, 1) * (page + 1) };
    },
    detail(id) {
        const $ = parseHTML(get(`${site}/vod-detail-id-${id}.html`));
        const playUrl = match(`mac_url='([^']*)'`, get(`${site}/vod-play-id-${id}-src-1-num-1.html`));
        const name = ($('.title > a:nth-child(1)').first().attr('title') || '').trim() || firstText($, null, '.title h1, h1, .vodh h2');
        return { list: [{
            vod_id: id, vod_name: name,
            vod_pic: url(firstAttr($, null, '.page-hd > a:nth-child(1) > img:nth-child(1), .page-hd img, .vodImg img, .pic img', 'data-src', 'data-original', 'src')),
            type_name: info($, '类型'), vod_area: info($, '地区'), vod_year: info($, '年份'), vod_actor: info($, '主演'), vod_director: info($, '导演'),
            vod_content: firstText($, null, '.vodplayinfo, .des, .content, .vod_content'),
            vod_play_from: '在线播放', vod_play_url: playUrl
        }] };
    },
    search(wd) {
        return { list: cards(parseHTML(get(`${site}/index.php?m=vod-search&wd=${encodeURIComponent(wd)}`))) };
    },
    play(flag, id) {
        const page = get(prefixed(playerPrefix(get(site + '/player/wwgz.js')), id));
        const inner = match(`src\\s*=\\s*'([^']+)'\\s*\\+\\s*videoUrl`, page);
        let stream = inner ? match(`url:\\s*'([^']*)'`, get(prefixed(inner, id))) : match(`url:\\s*'([^']*)'`, page);
        if (!stream) stream = match(`"url"\\s*:\\s*"([^"]+)"`, get(prefixed(playerPrefix(get(site + '/player/lzm3u8.js')), id)));
        if (stream && !stream.startsWith('http')) stream = url(stream);
        if (!stream) return { parse: 1, url: id };
        const result = { parse: 0, url: stream, header: headers() };
        if (stream.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
