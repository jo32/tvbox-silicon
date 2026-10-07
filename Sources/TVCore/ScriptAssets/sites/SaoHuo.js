// 骚火影视 (csp_SaoHuo): an HTML site; playback hands the player iframe to the app's sniffer (parse=1).
// ext: "https://shdy5.us" or {"site": ...}; without it the current address comes from http://shapp.us/.
import { parseHTML, textOf, firstText, firstAttr, absolute } from './_lite.js';

const UA = 'Mozilla/5.0 (Linux; Android 9; ALN-AL00 Build/PQ3B.190801.05281406; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36';
const FILTERS = JSON.parse('{"1":[{"key":"cateId","name":"类型","value":[{"n":"全部","v":"1"},{"n":"喜剧","v":"6"},{"n":"爱情","v":"7"},{"n":"恐怖","v":"8"},{"n":"动作","v":"9"},{"n":"科幻","v":"10"},{"n":"战争","v":"11"},{"n":"犯罪","v":"12"},{"n":"动画","v":"13"},{"n":"奇幻","v":"14"},{"n":"剧情","v":"15"},{"n":"冒险","v":"16"},{"n":"悬疑","v":"17"},{"n":"惊悚","v":"18"},{"n":"其他","v":"20"}]}],"2":[{"key":"cateId","name":"类型","value":[{"n":"全部","v":"2"},{"n":"国产剧","v":"20"},{"n":"TVB","v":"21"},{"n":"韩剧","v":"22"},{"n":"美剧","v":"23"},{"n":"日剧","v":"24"},{"n":"英剧","v":"25"},{"n":"台剧","v":"26"},{"n":"其他","v":"27"}]}],"3":[{"key":"cateId","name":"类型","value":[{"n":"全部","v":"4"},{"n":"搞笑","v":"38"},{"n":"恋爱","v":"39"},{"n":"热血","v":"40"},{"n":"格斗","v":"41"},{"n":"美少女","v":"42"},{"n":"魔法","v":"43"},{"n":"机战","v":"44"},{"n":"校园","v":"45"},{"n":"亲子","v":"46"},{"n":"童话","v":"47"},{"n":"冒险","v":"48"},{"n":"真人","v":"49"},{"n":"LOLI","v":"50"},{"n":"其他","v":"51"}]}]}');

let site = 'https://shdy2.com';
let cookie = '';

function headers() {
    const h = { 'User-Agent': UA, 'accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7', Referer: site + '/' };
    if (cookie) h.Cookie = cookie;
    return h;
}

function get(url) {
    try {
        const response = globalThis.req(url, { headers: headers() });
        const set = response.headers && (response.headers['set-cookie'] || response.headers['Set-Cookie']);
        if (set) cookie = String(Array.isArray(set) ? set[0] : set).split(/,(?=\s*[^;,=\s]+=)/)[0];
        return response.content || '';
    } catch { return ''; }
}

const url = path => absolute(site, path);

function cards(body) {
    const $ = parseHTML(body);
    const list = [], seen = new Set();
    $('.v_list li, .vlist li, ul.clearfix li, li:has(a[title]):has(img)').each((_, li) => {
        const href = firstAttr($, li, 'a[href]', 'href');
        const name = firstAttr($, li, 'a[title]', 'title') || firstText($, li, 'a[title], h3 a, h4 a, .title a, a[href]');
        if (!href || !name) return;
        const id = url(href);
        if (seen.has(id)) return;
        seen.add(id);
        list.push({ vod_id: id, vod_name: name, vod_pic: url(firstAttr($, li, 'img', 'data-original', 'data-src', 'src')), vod_remarks: firstText($, li, '.hdtag, .note, .pic-text, .remarks, span') });
    });
    return list;
}

export default {
    init(ext) {
        let value = String(ext || '').trim();
        if (value && !value.startsWith('http')) { try { value = JSON.parse(value).site || ''; } catch { value = ''; } }
        if (value) { site = value.replace(/\/+$/, ''); return; }
        try {
            const $ = parseHTML(globalThis.req('http://shapp.us/', { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36' } }).content);
            const found = $('.content-top a[href], a[href]').toArray().map(a => ($(a).attr('href') || '').trim()).find(h => h.startsWith('http'));
            if (found) site = found.replace(/\/+$/, '');
        } catch { /* keep the default */ }
    },
    home() {
        const classes = [['1', '电影'], ['2', '电视剧'], ['20', '国产剧'], ['4', '动漫']].map(([type_id, type_name]) => ({ type_id, type_name }));
        return { class: classes, list: cards(get(site)).slice(0, 6), filters: FILTERS };
    },
    category(tid, pg, filter, extend = {}) {
        const list = cards(get(`${site}/list/${extend.cateId || tid}-${pg}.html`));
        const page = parseInt(pg, 10);
        return { page, pagecount: page + 1, limit: list.length, total: Math.max(list.length, 1) * (page + 1), list };
    },
    detail(id) {
        const $ = parseHTML(get(url(id)));
        const name = firstText($, null, 'h1, .vodh h2, .detail-title, .title') || firstAttr($, null, 'meta[property="og:title"]', 'content');
        const item = {
            vod_id: id, vod_name: name, vod_pic: url(firstAttr($, null, '.thumb img, .cover img, .detail-pic img, img.lazy', 'data-original', 'data-src', 'src')),
            vod_content: '简介：' + firstText($, null, 'p.p_txt, .p_txt, .vod_content, .content, .detail-content')
        };
        const info = firstText($, null, '.info, .vod_info, .detail-info');
        if (info) {
            const parts = info.split(/ \/ 导演:| \/ 主演:/);
            item.type_name = (parts[0] || '').trim(); item.vod_director = (parts[1] || '').trim(); item.vod_actor = (parts[2] || '').trim();
        }
        const groups = $('#play_link li'), names = $('.play_from ul.from_list li');
        const froms = [], urls = [];
        groups.each((i, group) => {
            const title = i < names.length ? textOf(names.eq(i)) : `播放${i + 1}`;
            const links = $(group).find('a[href]').toArray().reverse().map(a => textOf($(a)) + '$' + ($(a).attr('href') || '').trim());
            if (links.length && !froms.includes(title)) { froms.push(title); urls.push(links.join('#')); }
        });
        item.vod_play_from = froms.join('$$$');
        item.vod_play_url = urls.join('$$$');
        return { list: [item] };
    },
    search(wd) {
        return { list: cards(get(`${site}/s----------.html?wd=${encodeURIComponent(wd)}`)) };
    },
    play(flag, id) {
        const $ = parseHTML(get(site + id));
        const frame = ($('iframe[src]').first().attr('src') || '').trim();
        return frame ? { parse: 1, url: url(frame), header: headers() } : { parse: 1, url: site + id };
    }
};
