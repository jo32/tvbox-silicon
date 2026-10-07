// 堇夏听书 (csp_TingBookJinXia): an HTML audiobook site; play pages expose meta _b/_cp/_c/_p values that
// the getneoplay API exchanges for the audio address (falling back to <audio id=player>).
// ext: site address (default https://m.ting15.com)
import { parseHTML, textOf } from './_lite.js';

const UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const CLASSES = [['wuxiaxuanhuan', '武侠玄幻'], ['kongbulingyi', '恐怖灵异'], ['tuilixuanyi', '推理悬疑'], ['dushiyanqing', '都市言情'], ['jiatinglunli', '家庭伦理'],
    ['wenxuemingzhu', '官场职场'], ['jingdianpingshu', '经典评书'], ['quyixiqu', '曲艺戏曲'], ['xiangshengxiaopin', '相声小品'], ['yinyue', '助眠音频']];
const ORDER = [{ key: 'order', name: '排序', value: [{ n: '默认', v: '' }, { n: '按人气', v: 'hits' }, { n: '按时间', v: 'addtime' }] }];

let site = 'https://m.ting15.com';

const get = url => { try { return globalThis.req(url, { headers: { 'User-Agent': UA } }).content || ''; } catch { return ''; } };
const picture = src => src ? `${src}@Referer=${site}/@User-Agent=${UA}` : '';

function books(html) {
    const $ = parseHTML(html);
    let links = $('.clist > a[href]');
    if (!links.length) links = $('section a[href$=".html"]:has(h3)');
    const list = [];
    links.each((_, a) => {
        const href = $(a).attr('href') || '';
        if (!href || href.startsWith('http')) return;
        let name = textOf($(a).find('h3'));
        if (name.startsWith('[') && name.includes(']')) name = name.slice(name.indexOf(']') + 1);
        const pic = picture($(a).find('dt img').first().attr('src') || '');
        let reader = '';
        $(a).find('dd p').each((__, p) => { const t = textOf($(p)); if (!reader && t.startsWith('播音')) reader = t.replace('播音：', '').replace('播音:', '').trim(); });
        if (name && pic) list.push({ vod_id: href, vod_name: name, vod_pic: pic, vod_remarks: reader });
    });
    return list;
}

export default {
    init(ext) { if (ext) site = String(ext).trim(); },
    home(filter) {
        const classes = CLASSES.map(([type_id, type_name]) => ({ type_id, type_name }));
        const home = { class: classes, list: books(get(site)) };
        if (filter) { home.filters = {}; for (const c of classes) home.filters[c.type_id] = ORDER; }
        return home;
    },
    category(tid, pg, filter, extend = {}) {
        const page = parseInt(pg, 10) || 1;
        const url = extend.order ? `${site}/${tid}/index${page}-order-${extend.order}.html` : `${site}/${tid}${page === 1 ? '/' : `/index${page}.html`}`;
        const html = get(url);
        const $ = parseHTML(html);
        let pages = page;
        $('.cpage span').each((_, span) => { const t = textOf($(span)); if (t.includes('/')) { const n = parseInt(t.split('/')[1], 10); if (n > 0) pages = n; } });
        return { page, pagecount: pages, limit: 10, total: pages * 10, list: books(html) };
    },
    detail(id) {
        const $ = parseHTML(get(site + id));
        let reader = '', author = '', state = '', intro = '';
        $('.binfo p').each((_, p) => {
            const t = textOf($(p));
            if (t.startsWith('播音')) reader = t.slice(3); else if (t.startsWith('作者')) author = t.slice(3); else if (t.startsWith('状态')) state = t.slice(3);
        });
        $('.intro p').each((_, p) => { const t = textOf($(p)); if (!intro && t && !t.includes('下载APP') && t.length > 20) intro = t; });
        const episodes = $('.plist a.f').toArray().map(a => [($(a).attr('href') || ''), textOf($(a))]).filter(([h, t]) => h && t).map(([h, t]) => `第${t}集$${h}`);
        return { list: [{
            vod_id: id, vod_name: textOf($('.binfo h1')), vod_pic: picture($('.bimg img').first().attr('src') || ''), vod_actor: reader,
            vod_director: author, vod_remarks: state, vod_content: intro, vod_play_from: '堇夏', vod_play_url: episodes.join('#')
        }] };
    },
    search(wd) { return { list: books(get(`${site}/?s=ting-search-wd-${encodeURIComponent(wd)}`)) }; },
    play(flag, id) {
        const $ = parseHTML(get(site + id));
        const meta = name => ($(`meta[name=${name}]`).first().attr('content') || '');
        const book = meta('_b'), page = meta('_cp'), xt = meta('_c'), pay = meta('_p');
        let url = '';
        if (book && page) {
            const headers = { 'User-Agent': UA, Referer: site + id };
            if (xt) headers.xt = xt;
            try {
                const answer = globalThis.req(site + '/?s=api-getneoplay', { method: 'POST', data: { bookId: book, isPay: pay, page }, headers }).content || '';
                const data = JSON.parse(answer.replace(/^\uFEFF/, ''));  // the API prefixes a byte-order mark
                if (Number(data.status) === 1) url = String(data.ourl || data.url || '');
            } catch { /* fall back to the audio element */ }
        }
        if (!url) url = $('audio#player').first().attr('src') || '';
        if (url) return { parse: 0, url, header: { 'User-Agent': UA, Referer: site + '/' } };
        return { parse: 1, url: site + id, header: { 'User-Agent': UA } };
    }
};
