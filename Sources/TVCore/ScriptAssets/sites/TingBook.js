// 六月听书 (csp_TingBook): an HTML audiobook site; chapter audio comes from getchapterurl, sometimes
// encoded as "*"-separated character codes (jsjm=1).
// ext: "https://app.365ting.com" or {"site"|"url": ...}
import { parseHTML, textOf } from './_lite.js';

const HEADERS = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' };
const CLASSES = [['6', '玄幻奇幻'], ['7', '都市言情'], ['8', '宫斗女频'], ['9', '官场商战'], ['10', '武侠仙侠'], ['11', '刑侦推理'], ['12', '探险科幻'], ['13', '重生穿越'],
    ['14', '恐怖惊悚'], ['15', '文学历史'], ['31', '评书相声'], ['49', '两性情感'], ['51', '儿童文学'], ['52', '国学启蒙'], ['53', '家教育儿'], ['54', '卡通动画']];

let site = 'https://app.365ting.com';

const get = url => { try { return globalThis.req(url, { headers: HEADERS }).content || ''; } catch { return ''; } };
const image = node => { const v = node.attr('data-original') || node.attr('data-src') || node.attr('src') || ''; return v.startsWith('//') ? 'https:' + v : v; };

function books(html) {
    const $ = parseHTML(html);
    const list = [];
    $('a[href^="/book/"]').each((_, a) => {
        const href = $(a).attr('href') || '';
        const heading = $(a).find('h2').first();
        if (!/^\/book\/\d+\.html$/.test(href) || !heading.length) return;
        let name = textOf(heading), remarks = '';
        const bar = name.indexOf('|');
        if (bar > 0) { remarks = name.slice(0, bar).trim(); name = name.slice(bar + 1).trim(); }
        if (name) list.push({ vod_id: href, vod_name: name, vod_pic: image($(a).find('img').first()), vod_remarks: remarks });
    });
    return list;
}

function chapters($, out) {
    $('a.list-item[href^="/play/"]').each((_, a) => {
        const href = $(a).attr('href') || '';
        let name = textOf($(a));
        const title = ($(a).attr('title') || '').trim();
        const space = title.lastIndexOf(' ');
        if (title && space >= 0 && space < title.length - 1) name = title.slice(space + 1).trim();
        if (href && name) out.push(`${name}$${href}`);
    });
}

function decodeSource(kind, value) {
    let text = String(value || '').replace(/\\\//g, '/').trim();
    if (!text) return '';
    if (kind === 1 || /^\d+(\*\d+)+$/.test(text)) text = text.split('*').filter(Boolean).map(n => String.fromCharCode(parseInt(n, 10))).join('');
    return text.startsWith('//') ? 'https:' + text : text;
}

export default {
    init(ext) {
        const value = String(ext || '').trim();
        if (value) { try { const c = JSON.parse(value); site = c.site || c.url || site; } catch { site = value; } }
        site = site.replace(/\/$/, '');
    },
    home() { return { class: CLASSES.map(([type_id, type_name]) => ({ type_id, type_name })), list: books(get(site + '/category/6/2/1.html')) }; },
    category(tid, pg) { return { list: books(get(`${site}/category/${tid}/2/${pg}.html`)) }; },
    detail(id) {
        let html = '';
        for (let attempt = 0; attempt < 3; attempt++) { html = get(site + id); if (!html.includes('System Error')) break; }
        const $ = parseHTML(html);
        const info = {};
        $('.extra').each((_, extra) => {
            const label = $(extra).contents().filter((__, n) => n.type === 'text').text().trim();
            const span = $(extra).find('span.text').first();
            const value = span.length ? textOf(span.find('a').first().length ? span.find('a').first() : span) : '';
            for (const key of ['类型', '主播', '原著', '状态']) if (label.startsWith(key)) info[key] = value;
        });
        const list = [];
        chapters($, list);
        let pages = 1;
        $('ul.pagination li a[href]').each((_, a) => {
            const href = $(a).attr('href') || '';
            const at = href.indexOf('page=');
            if (at >= 0) { const n = parseInt(href.slice(at + 5).replace(/[^0-9]/g, ''), 10); if (n > pages) pages = n; }
        });
        for (let page = 2; page <= pages && page <= 200; page++) chapters(parseHTML(get(`${site}${id}${id.includes('?') ? '&' : '?'}page=${page}`)), list);
        const cover = $('.book-detail img.img').first().length ? $('.book-detail img.img').first() : $('img[alt]').first();
        return { list: [{
            vod_id: id, vod_name: textOf($('h2.book-title').first()) || textOf($('h1.title').first()), vod_pic: image(cover),
            vod_content: textOf($('.book-intro').first()), vod_actor: info['主播'] || '', vod_director: info['原著'] || '', type_name: info['类型'] || '',
            vod_remarks: info['状态'] || '', vod_play_from: '六月', vod_play_url: list.join('#')
        }] };
    },
    search(wd) { return { list: books(get(`${site}/pc/index/search/keyword/${encodeURIComponent(wd)}.html`)) }; },
    play(flag, id) {
        const parts = id.replace('/play/', '').replace('.html', '').split('/');
        if (parts.length >= 2) {
            try {
                const data = JSON.parse(get(`${site}/pc/index/getchapterurl/bookId/${parts[0]}/chapterId/${parts[1]}/timestamp/${Math.floor(Date.now() / 1000)}.html`));
                const url = decodeSource(Number(data.jsjm) || 0, data.src);
                if (url) return { parse: 0, url, header: HEADERS };
            } catch { /* fall back to the web page */ }
        }
        return { parse: 1, url: site + id, header: HEADERS };
    }
};
