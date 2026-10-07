// 天堂影视 (csp_TvDy): a stui MacCMS site; playback reads player_aaaa from the play page.
import { parseHTML, textOf, match } from './_lite.js';

const SITE = 'https://www.tvdy.xyz';
const HEADERS = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36' };

const get = url => { try { return globalThis.req(url, { headers: HEADERS }).content || ''; } catch { return ''; } };
const pic = p => p && !p.startsWith('http') ? SITE + p : p;

function cards(body, remarks) {
    const $ = parseHTML(body);
    const list = [];
    $('a.stui-vodlist__thumb').each((_, a) => {
        const node = $(a);
        const name = node.attr('title') || '';
        const href = node.attr('href') || '';
        const id = match('/(\\d+)\\.html', href);
        if (!name || !id) return;
        const image = node.attr('data-original') || match("url\\(['\"]?([^'\"\\)]+)['\"]?\\)", node.attr('style') || '');
        const item = { vod_id: id, vod_name: name, vod_pic: pic(image) };
        if (remarks) item.vod_remarks = textOf(node.find('.pic-text').first());
        list.push(item);
    });
    return list;
}

export default {
    home() {
        return {
            class: [['dianying', '电影'], ['dianshiju', '电视剧'], ['zongyi', '综艺'], ['dongman', '动漫']].map(([type_id, type_name]) => ({ type_id, type_name })),
            list: cards(get(SITE), true)
        };
    },
    category(tid, pg) {
        const list = cards(get(`${SITE}/vodtype/${tid}-${pg}.html`), true);
        const page = parseInt(pg, 10);
        return { page, pagecount: page + 1, limit: 20, total: (page + 1) * 20, list };
    },
    detail(id) {
        const $ = parseHTML(get(`${SITE}/voddetail/${id}.html`));
        const img = $('a[href*=voddetail] img').first();
        const image = img.attr('data-original') || img.attr('src') || '';
        let lists = $('ul[class*=content__playlist]');
        if (!lists.length) lists = $('ul:has(a[href*=vodplay])');
        const episodes = [];
        lists.first().find('a[href*=vodplay]').each((_, a) => {
            episodes.push(textOf($(a)) + '$' + ($(a).attr('href') || '').replace(/.*\/vodplay\/(.*?)\.html.*/, '$1'));
        });
        return { list: [{
            vod_id: id, vod_name: textOf($('h1').first()), vod_pic: pic(image),
            vod_content: textOf($('p:contains(简介)').first()).replace('简介：', ''),
            vod_play_from: '在线播放', vod_play_url: episodes.join('#')
        }] };
    },
    search(wd) {
        return { list: cards(get(`${SITE}/vodsearch/-${encodeURIComponent(wd)}------------.html`), false) };
    },
    play(flag, id) {
        const body = get(`${SITE}/vodplay/${id}.html`);
        const encrypt = parseInt(match('"encrypt"\\s*:\\s*(\\d+)', body) || '0', 10);
        let url = match('player_aaaa\\s*=\\s*\\{.*?"url"\\s*:\\s*"([^"]+)"', body);
        if (!url) {
            const m3u8 = match(`(https?://[^"'\\s]+\\.m3u8[^"'\\s]*)`, body);
            if (!m3u8) return { parse: 0, url: '', msg: '解析失败' };
            return { parse: 0, url: m3u8, header: HEADERS, format: 'application/x-mpegURL' };
        }
        url = url.replace(/\\\//g, '/');
        if (encrypt === 2) url = decodeURIComponent(Buffer.from(url, 'base64').toString('latin1'));
        else if (encrypt === 1) url = decodeURIComponent(url);
        const result = { parse: 0, url, header: HEADERS };
        if (url.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
