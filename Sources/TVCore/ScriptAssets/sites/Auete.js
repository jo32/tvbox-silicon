// 奥特 (fty csp_AueteGuard): auete.cc pages. Video ids are "<type>/<sub>/<id>"; episodes are play-page paths whose
// script sets `now` to the media URL (sometimes base64(...); bare m3u8 paths live on the haozhansou cache host).
// ext: {"siteUrl": "https://..."} optional.
import { parseHTML, textOf } from './_lite.js';

const FILTERS = {"Movie": [{"key": 0, "name": "分类", "value": [{"n": "全部", "v": ""}, {"n": "喜剧片", "v": "xjp"}, {"n": "动作片", "v": "dzp"}, {"n": "爱情片", "v": "aqp"}, {"n": "科幻片", "v": "khp"}, {"n": "恐怖片", "v": "kbp"}, {"n": "惊悚片", "v": "jsp"}, {"n": "战争片", "v": "zzp"}, {"n": "剧情片", "v": "jqp"}]}], "Tv": [{"key": 0, "name": "分类", "value": [{"n": "全部", "v": ""}, {"n": "美剧", "v": "oumei"}, {"n": "韩剧", "v": "hanju"}, {"n": "日剧", "v": "riju"}, {"n": "泰剧", "v": "yataiju"}, {"n": "网剧", "v": "wangju"}, {"n": "台剧", "v": "taiju"}, {"n": "国产", "v": "neidi"}, {"n": "港剧", "v": "tvbgj"}]}], "Zy": [{"key": 0, "name": "分类", "value": [{"n": "全部", "v": ""}, {"n": "国综", "v": "guozong"}, {"n": "韩综", "v": "hanzong"}, {"n": "美综", "v": "meizong"}]}], "Dm": [{"key": 0, "name": "分类", "value": [{"n": "全部", "v": ""}, {"n": "动画", "v": "donghua"}, {"n": "日漫", "v": "riman"}, {"n": "国漫", "v": "guoman"}, {"n": "美漫", "v": "meiman"}]}], "qita": [{"key": 0, "name": "分类", "value": [{"n": "全部", "v": ""}, {"n": "纪录片", "v": "Jlp"}, {"n": "经典片", "v": "Jdp"}, {"n": "经典剧", "v": "Jdj"}, {"n": "网大电影", "v": "wlp"}, {"n": "国产老电影", "v": "laodianying"}]}]};
const LINES = {"byun": {"sh": "云播B线", "pu": "", "sn": 0, "or": 999}, "yyun": {"sh": "云播Y线", "pu": "", "sn": 0, "or": 999}, "cyun": {"sh": "云播C线", "pu": "", "sn": 0, "or": 999}, "dbm3u8": {"sh": "云播D线", "pu": "", "sn": 0, "or": 999}, "i8i": {"sh": "云播E线", "pu": "", "sn": 0, "or": 999}, "m3u8hd": {"sh": "云播F线", "pu": "https://haozhansou.com/api/mp.php?url=", "sn": 1, "or": 999}, "oyun": {"sh": "云播O线", "pu": "https://haozhansou.com/api/mp.php?url=", "sn": 1, "or": 999}, "languang": {"sh": "云播G线", "pu": "https://haozhansou.com/api/mp.php?url=", "sn": 1, "or": 999}, "hyun": {"sh": "云播H线", "pu": "https://haozhansou.com/api/mp.php?url=", "sn": 1, "or": 999}, "kyun": {"sh": "云播K线", "pu": "https://haozhansou.com/api/mp.php?url=", "sn": 1, "or": 999}, "xun": {"sh": "云播X线", "pu": "", "sn": 0, "or": 999}, "bpyueyu": {"sh": "云播粤语", "pu": "", "sn": 0, "or": 999}, "bpguoyu": {"sh": "云播国语", "pu": "", "sn": 0, "or": 999}, "lyun": {"sh": "云播L线", "pu": "https://haozhansou.com/api/mp.php?url=", "sn": 1, "or": 999}, "myun": {"sh": "云播M线", "pu": "", "sn": 0, "or": 999}, "dp": {"sh": "Dplayer", "pu": "", "sn": 0, "or": 999}};
const HEADERS = {
    'Upgrade-Insecure-Requests': '1', DNT: '1', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36',
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.8,zh-TW;q=0.7,zh-HK;q=0.5,en-US;q=0.3,en;q=0.2'
};
const CLASS_NAMES = ['电影', '电视剧', '综艺', '动漫'];

let host = 'https://auete.cc/';
const fetchText = url => String(globalThis.req(url, { headers: HEADERS }).content || '');

function cards($) {
    return $('ul.threadlist li').toArray().map(el => {
        const item = $(el);
        const title = item.find('h2 a').first().attr('title') || '';
        const id = ((item.find('a').first().attr('href') || '').match(/\/(\w+\/\w+\/\w+)\//) || [])[1];
        if (!title.trim() || !id || id.includes('/jqp/')) return null;
        return { vod_id: id, vod_name: title, vod_pic: item.find('a.pic img').first().attr('src') || '', vod_remarks: textOf(item.find('span.hdtag').first()) };
    }).filter(Boolean);
}

export default {
    init(ext) {
        try { const c = JSON.parse(String(ext || '{}')); if (String(c.siteUrl || '').startsWith('http')) host = c.siteUrl; } catch {}
    },
    home(filter) {
        const $ = parseHTML(fetchText(host));
        const classes = $("ul[class='navbar-nav mr-auto'] > li a").toArray().map(el => {
            const name = textOf($(el));
            const id = (($(el).attr('href') || '').match(/\/(\w+)\/index.html/) || [])[1];
            return CLASS_NAMES.includes(name) && id ? { type_id: id.trim(), type_name: name } : null;
        }).filter(Boolean);
        const result = { class: classes, list: cards($) };
        if (filter) result.filters = FILTERS;
        return result;
    },
    category(tid, pg, filter, extend = {}) {
        const value = Object.values(extend || {}).filter(v => v && v.trim()).pop();
        const base = value ? `${host}/${tid}/${value}` : `${host}/${tid}`;
        const page = parseInt(pg, 10) || 1;
        const html = fetchText(page === 1 ? `${base}/index.html` : `${base}/index${page}.html`);
        const $ = parseHTML(html);
        let current = page, last = page;
        $('ul.pagination li').each((_, el) => {
            const a = $(el).find('a').first();
            const index = ((a.attr('href') || '').match(/\/index(\d+).html/) || [])[1];
            if ($(el).hasClass('active')) current = index ? parseInt(index, 10) : current;
            if (textOf(a) === '尾页' && index) last = parseInt(index, 10);
        });
        const list = html.includes('没有找到您想要的结果哦') ? [] : cards($);
        return { page: current, pagecount: Math.max(last, current), limit: 20, total: last <= 1 ? list.length : last * 20, list };
    },
    detail(id) {
        const $ = parseHTML(fetchText(`${host}/${id}/`));
        const card = $('div.detail-main-card').first();
        const name = textOf($('h1.detail-title').first()).replace(/[《》]/g, '') || card.attr('data-pname') || '';
        const pic = $('div.detail-poster img').first().attr('src') || card.attr('data-ppic') || '';
        const info = { type_name: '', vod_year: '', vod_area: '', vod_remarks: '', vod_actor: '', vod_director: '', vod_content: '' };
        const labels = { 分类: 'type_name', 导演: 'vod_director', 主演: 'vod_actor', 地区: 'vod_area', 年份: 'vod_year', 备注: 'vod_remarks' };
        $('div.message p').each((_, el) => {
            const p = $(el);
            if (p.hasClass('detail-section-title')) return;
            if (p.hasClass('detail-des')) { info.vod_content = textOf(p); return; }
            const label = textOf(p.find('span.detail-label').first());
            const value = textOf(p.find('b').first()) || textOf(p);
            for (const [word, key] of Object.entries(labels)) if (label.includes(word)) { info[key] = value; break; }
        });
        const lines = [];
        $('div.play-card#player_list').each((_, el) => {
            const card = $(el);
            let title = textOf(card.find('div.card-header span b').first());
            if (!title) return;
            title = title.slice(title.lastIndexOf('』') + 1);
            const key = Object.keys(LINES).find(k => LINES[k].sh === title);
            if (!key) return;
            const episodes = card.find('ul.episode-list li > a').toArray().map(a => {
                const path = (($(a).attr('href') || '').match(/(\/\w+\/\w+\/\w+\/play-\d+-\d+.html)/) || [])[1];
                return path ? `${textOf($(a))}$${path}` : null;
            }).filter(Boolean);
            if (episodes.length) lines.push([key, episodes.join('#')]);
        });
        const vod = { vod_id: id, vod_name: name, vod_pic: pic, ...info };
        if (lines.length) { vod.vod_play_from = lines.map(l => l[0]).join('$$$'); vod.vod_play_url = lines.map(l => l[1]).join('$$$'); }
        return { list: [vod] };
    },
    search(wd, quick, pg) {
        const page = parseInt(pg, 10) || 1;
        const url = `${host}auete4so.php?searchword=${encodeURIComponent(wd)}` + (page > 1 ? `&page=${page}` : '');
        return { list: cards(parseHTML(fetchText(url))) };
    },
    play(flag, id) {
        const $ = parseHTML(fetchText(host + id));
        for (const script of $('div > script').toArray().map(el => $(el).html() || '')) {
            for (const part of script.split('var')) {
                const m = part.trim().match(/^now\s*=\s*(.*)/);
                if (!m) continue;
                let value = m[1].replace(/"/g, '').replace(/;/g, '').trim();
                const b64 = value.startsWith('base64') && value.match(/\(([^)]*)\)/);
                if (b64) { let s = b64[1]; while (s.length % 4) s += '='; value = Buffer.from(s, 'base64').toString('utf8'); }
                if (value.startsWith('http')) return { parse: 0, url: value };
                if (value.includes('m3u8')) return { parse: 0, url: 'https://datas-s8pwfqdu9yystn90fb----------------cache.haozhansou.com/' + value };
            }
        }
        return { parse: 0, url: '' };
    }
};
