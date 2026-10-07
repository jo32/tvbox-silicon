// 兔小贝 (csp_TuXiaoBei): HTML pages; the play page's <video> (or #videoWrap video-src) is the stream.
import { parseHTML, textOf } from './_lite.js';

const SITE = 'https://www.tuxiaobei.com';
const DESKTOP = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
const MOBILE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1';
const CLASSES = [['erge', '儿歌'], ['gushi', '故事'], ['guoxue', '国学'], ['gongyi', '公益']];

const headers = (ua = DESKTOP) => ({ 'User-Agent': ua, Referer: SITE + '/' });
const get = (url, ua) => { try { return globalThis.req(url, { headers: headers(ua) }).content || ''; } catch { return ''; } };

function cards(html, paragraphs, limit = Infinity, stripCounts = true) {
    const $ = parseHTML(html);
    const list = [], seen = new Set();
    $('a[href^="/play/"]').each((_, a) => {
        if (list.length >= limit) return;
        const id = ($(a).attr('href') || '').replace('/play/', '');
        if (!id || seen.has(id)) return;
        let name = '', remarks = '';
        $(a).find(paragraphs).each((__, p) => {
            const value = textOf($(p));
            if (!value) return;
            if (value.includes('播放') || value.includes('万')) remarks = value.replace('播放：', '');
            else if (!name && !/^\d+$/.test(value)) name = value;
        });
        if (!name) { name = textOf($(a)).replace(/播放.*/, ''); if (stripCounts) name = name.replace(/\d+\.?\d*万/g, ''); name = name.trim(); }
        if (!name) return;
        seen.add(id);
        list.push({ vod_id: id, vod_name: name, vod_pic: $(a).find('img').first().attr('src') || '', vod_remarks: remarks });
    });
    return list;
}

export default {
    home() { return { class: CLASSES.map(([type_id, type_name]) => ({ type_id, type_name })), list: cards(get(SITE + '/animate'), 'p, paragraph, generic', 30, false) }; },
    category(tid) { return { list: cards(get(`${SITE}/${tid}`), 'p, paragraph') }; },
    detail(id) {
        const $ = parseHTML(get(`${SITE}/play/${id}`));
        const name = textOf($('.video-detail .title')) || textOf($('title')).split('-')[0].trim();
        return { list: [{
            vod_id: id, vod_name: name, vod_pic: $('.video-play-box img').first().attr('src') || '', type_name: textOf($('.video-detail .type')),
            vod_remarks: textOf($('.video-detail .count')), vod_content: textOf($('.video-detail .desc')) || name, vod_play_from: '兔小贝', vod_play_url: '播放$' + id
        }] };
    },
    search(wd) { return { list: cards(get(`${SITE}/search/index?key=${encodeURIComponent(wd)}`), 'p') }; },
    play(flag, id) {
        const $ = parseHTML(get(`${SITE}/play/${id}`, MOBILE));
        const url = $('#videoWrap video').first().attr('src') || $('#videoWrap').first().attr('video-src') || '';
        return { parse: 0, url, header: headers(MOBILE) };
    }
};
