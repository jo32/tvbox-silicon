// 荐影 (fty csp_YGPGuard): 6huo.com trailers. A category URL is <type>_<f1>_<f2>_<f3>_<page> from filter keys 0-3.
import { parseHTML, textOf } from './_lite.js';

const HOST = 'https://www.6huo.com/';
const FILTERS = {"movlist/":[{"key":"1","name":"类型","value":[{"n":"全部","v":""},{"n":"喜剧","v":"喜剧"},{"n":"爱情","v":"爱情"},{"n":"恐怖","v":"恐怖"},{"n":"动作","v":"动作"},{"n":"科幻","v":"科幻"},{"n":"剧情","v":"剧情"},{"n":"战争","v":"战争"},{"n":"犯罪","v":"犯罪"},{"n":"灾难","v":"灾难"},{"n":"奇幻","v":"奇幻"},{"n":"悬疑","v":"悬疑"},{"n":"惊悚","v":"惊悚"},{"n":"冒险","v":"冒险"}]},{"key":"0","name":"地区","value":[{"n":"全部","v":""},{"n":"大陆","v":"大陆"},{"n":"香港","v":"香港"},{"n":"台湾","v":"台湾"},{"n":"美国","v":"美国"},{"n":"法国","v":"法国"},{"n":"英国","v":"英国"},{"n":"日本","v":"日本"},{"n":"韩国","v":"韩国"},{"n":"德国","v":"德国"},{"n":"泰国","v":"泰国"},{"n":"印度","v":"印度"},{"n":"其他","v":"其他"}]},{"key":"2","name":"年份","value":[{"n":"全部","v":""},{"n":"2026","v":"2026"},{"n":"2025","v":"2025"},{"n":"2024","v":"2024"},{"n":"2023","v":"2023"},{"n":"2022","v":"2022"},{"n":"2021","v":"2021"},{"n":"2020","v":"2020"},{"n":"2019","v":"2019"},{"n":"2018","v":"2018"},{"n":"2017","v":"2017"},{"n":"2016","v":"2016"},{"n":"2015","v":"2015"},{"n":"2014","v":"2014"},{"n":"2013","v":"2013"},{"n":"2012","v":"2012"},{"n":"2011","v":"2011"},{"n":"2010","v":"2010"},{"n":"2009","v":"2009"},{"n":"2008","v":"2008"},{"n":"2007","v":"2007"},{"n":"2006","v":"2006"},{"n":"2005","v":"2005"},{"n":"2004","v":"2004"},{"n":"2003","v":"2003"},{"n":"2002","v":"2002"},{"n":"2001","v":"2001"},{"n":"2000","v":"2000"},{"n":"1999","v":"1999"},{"n":"1998","v":"1998"},{"n":"1980","v":"1980"}]},{"key":"3","name":"排序","value":[{"n":"全部","v":""},{"n":"最近更新","v":""},{"n":"上映时间","v":"pubtime"}]}]};
const HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36',
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9',
    'Accept-Language': 'zh-CN,zh;q=0.9'
};
const NO_TRAILER = '暂无预告';

const fetchText = url => String(globalThis.req(url, { headers: HEADERS }).content || '');
const pick = (re, text) => { const m = text.match(re); return m ? m[1].trim() : text; };
function cards($, selector) {
    return $(selector).toArray().map(el => {
        const a = $(el);
        let pic = a.find('img').first().attr('src') || '';
        if (!pic.includes('http')) pic = HOST + pic;
        return { vod_id: a.attr('href') || '', vod_name: a.find('span').first().attr('title') || '', vod_pic: pic, vod_remarks: textOf(a.find('span').last()) };
    });
}

export default {
    home(filter) {
        const result = { class: [{ type_id: 'movlist/', type_name: '新片预告' }], list: cards(parseHTML(fetchText(HOST)), 'div.movlist > ul li > a') };
        if (filter) result.filters = FILTERS;
        return result;
    },
    category(tid, pg, filter, extend = {}) {
        const parts = ['', '', '', '', String(pg || '1')];
        for (const [key, value] of Object.entries(extend || {})) { const i = parseInt(key, 10); if (i >= 0 && i < 4) parts[i] = encodeURIComponent(value); }
        const html = fetchText(HOST + tid + parts.join('_'));
        const $ = parseHTML(html);
        const links = $('p.page-nav a');
        let page = parseInt(pg, 10) || 1, pagecount = page;
        if (links.length) {
            pagecount = Math.max(0, ...links.toArray().map(a => parseInt(textOf($(a)), 10)).filter(n => !isNaN(n)));
            page = parseInt(textOf($('p.page-nav a.current')), 10) || page;
        }
        const list = html.includes('没有找到您想要的结果哦') ? [] : cards($, 'div.inner-2col-main div.movlist > ul li > a');
        return { page, pagecount, limit: 30, total: pagecount <= 1 ? list.length : pagecount * 30, list };
    },
    detail(id) {
        const html = fetchText(HOST + String(id).replace(/^\//, ''));
        const $ = parseHTML(html);
        let pic = $('div.movie-title-mpic > a > img').first().attr('src') || '';
        if (!pic.includes('http')) pic = HOST + pic;
        let type = '', area = '';
        $('div.movie-title-detail a').each((_, el) => {
            const href = $(el).attr('href') || '';
            if (href.includes('country')) area = textOf($(el));
            if (href.includes('movietype')) type += textOf($(el)) + '/';
        });
        const info = textOf($('div.movie-title-detail p'));
        const froms = [], urls = [];
        if (!html.includes(NO_TRAILER)) {
            $('div.inner-wrapper a.current').each((_, tab) => {
                const name = textOf($(tab));
                if (!name.includes('预告')) return;
                const episodes = [];
                let title = '';
                $('div#tabwrapper-all tr td a').each((_, a) => {
                    const link = $(a);
                    if (link.hasClass('tlist-bbs-tdtitle')) title = textOf(link);
                    if (link.is('.btn-big.btn-green.tlist-btn')) episodes.push(`${title}$${link.attr('href') || ''}`);
                });
                if (episodes.length) { froms.push(name); urls.push(episodes.join('#')); }
            });
        }
        return { list: [{
            vod_id: id, vod_name: textOf($('h1.movie-name')), vod_pic: pic, type_name: type, vod_area: area, vod_remarks: '',
            vod_year: pick(/上映：(\w+)/, info), vod_director: pick(/导演：(.+)主演/, info), vod_actor: pick(/主演：(.+)剧情/, info), vod_content: pick(/剧情：(.+)\(详细\)/, info),
            vod_play_from: froms.length ? froms.join('$$$') : NO_TRAILER, vod_play_url: urls.length ? urls.join('$$$') : `${NO_TRAILER}$www`
        }] };
    },
    search(wd) {
        return { list: cards(parseHTML(fetchText(`${HOST}?keyword=${encodeURIComponent(wd)}&view=search`)), 'div.movlist > ul li > a') };
    },
    play(flag, id) {
        const ttid = String(id).split('/')[2];
        const data = JSON.parse(fetchText(`${HOST}?view=api&mode=download-data&rand=${Math.random()}&ttid=${ttid}`));
        return { parse: 0, playUrl: '', url: String((data[0] || {}).movurl || '') };
    }
};
