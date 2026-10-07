// 急救教学 (fty csp_FirstAidGuard): youlai.cn first-aid video pages. A category id is "<page>|<section index>".
import { parseHTML, textOf } from './_lite.js';

const HOST = 'https://m.youlai.cn';
const UA = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.163 Safari/537.36';
const CLASSES = ['急救技能', '家庭生活', '急危重症', '常见损伤', '动物致伤', '海洋急救', '中毒急救', '意外事故'];

const page = url => parseHTML(globalThis.req(url, { headers: { 'User-Agent': UA } }).content);

export default {
    home() { return { class: CLASSES.map((type_name, i) => ({ type_id: `jijiu|${i}`, type_name })) }; },
    category(tid, pg, filter, extend = {}) {
        const [path, index] = String(tid).split('|');
        const n = parseInt(index, 10) || 0;
        const $ = page(`${HOST}/${extend.cateId || path}`);
        const pic = $('.block100').eq(n).attr('src') || '';
        const list = $('.jj-title-li').eq(n).find('.list-br3').toArray().map(el => {
            const a = $(el).find('a');
            return { vod_id: HOST + (a.attr('href') || ''), vod_name: textOf(a), vod_pic: pic };
        });
        return { page: parseInt(pg, 10) || 1, pagecount: 1, limit: list.length, total: list.length, list };
    },
    detail(id) {
        const $ = page(id);
        const name = textOf($('.video-title.h1-title'));
        return { list: [{
            vod_id: id, vod_name: name, vod_pic: $('.video-cover.list-flex-in img').attr('src') || '', vod_area: '中国',
            vod_actor: textOf($('span.doc-name')), vod_content: textOf($('.img-text-con')),
            vod_play_from: 'Qile', vod_play_url: `${name}$${$('#video source').attr('src') || ''}`
        }] };
    },
    search(wd) {
        const $ = page(`${HOST}/cse/search?q=${encodeURIComponent(wd)}`);
        return { list: $('.search-video-li.list-br2').toArray().map(el => {
            const item = $(el);
            const pic = item.find('dt.logo-bg img').attr('src') || '';
            return { vod_id: HOST + (item.find('a').attr('href') || ''), vod_name: textOf(item.find('h5.line-clamp1')), vod_pic: pic.startsWith('https') ? pic : 'https:' + pic };
        }) };
    },
    play(flag, id) { return { parse: 0, url: id }; }
};
