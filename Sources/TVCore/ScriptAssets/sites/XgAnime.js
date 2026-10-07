// 西瓜卡通 (csp_XgAnime): an AMP site plus its cartoon-list JSON API; episode pages embed the
// pframe player whose vid= maps to https://xgct-video.bzcdn.net/<vid>/playlist.m3u8.
import { parseHTML, textOf } from './_lite.js';

const SITE = 'https://cn1.xgcartoon.com';
const FRAME = 'https://pframe.xgcartoon.com';
const UA = 'Mozilla/5.0 (Linux; Android 10; SM-G973F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const FILTER_KEYS = { 地区: 'region', 状态: 'state', 首字母: 'filter', 类型: 'type' };

const headers = referer => ({ 'User-Agent': UA, Referer: referer });
const get = (url, referer = SITE + '/') => { try { return globalThis.req(url, { headers: headers(referer) }).content || ''; } catch { return ''; } };
const join = (separator, values) => values.map(v => String(v || '').trim()).filter(Boolean).join(separator);
const playlist = vid => `https://xgct-video.bzcdn.net/${vid}/playlist.m3u8`;

function vidOf(html) {
    const host = FRAME.slice(FRAME.indexOf('://') + 3) + '/player.htm';
    const $ = parseHTML(html);
    const frame = $('iframe').toArray().map(f => $(f).attr('src') || '').find(src => src.includes(host) && /vid=/.test(src));
    const found = frame && /[?&]vid=([^&]+)/i.exec(frame);
    return found ? found[1] : '';
}

function hot(html, index) {
    const $ = parseHTML(html);
    const block = $('.index-hot').eq(index);
    const list = [];
    block.find('.index-hot-item').each((_, item) => {
        const a = $(item).find('a.title[href^="/detail/"]').first();
        if (!a.length) return;
        const id = (a.attr('href') || '').slice(8).trim(), name = textOf(a.find('.h3').first());
        if (!id || !name) return;
        const img = $(item).find('a.cover amp-img, a.cover img').first();
        list.push({ vod_id: id, vod_name: name, vod_pic: (img.attr('src') || '').trim(), vod_remarks: textOf($(item).find('.author').first()) });
    });
    return list;
}

export default {
    home() {
        const classes = [['hot', '热门动画'], ['hot_cn', '热门国产动画'], ['recent', '最近更新']].map(([type_id, type_name]) => ({ type_id, type_name }));
        const $ = parseHTML(get(SITE + '/classify'));
        const groups = [];
        $('.filter').each((_, filter) => {
            const title = textOf($(filter).find('.filter-head .h2').first());
            const key = FILTER_KEYS[title];
            if (!key) return;
            const values = [], seen = new Set();
            $(filter).find('.filter-item a[href]').each((__, a) => {
                const href = $(a).attr('href') || '';
                const query = new URLSearchParams(href.includes('?') ? href.slice(href.indexOf('?') + 1) : '');
                const value = (query.get(key) || '').trim(), name = textOf($(a));
                if (value && name && !seen.has(value)) { seen.add(value); values.push({ n: name, v: value }); }
            });
            if (values.length) groups.push({ key, name: title, value: values });
        });
        const filters = {};
        for (const c of classes) filters[c.type_id] = groups;
        return { class: classes, filters };
    },
    homeVod() {
        const html = get(SITE + '/');
        const list = hot(html, 0), seen = new Set(list.map(v => v.vod_id));
        for (const v of hot(html, 1)) if (!seen.has(v.vod_id)) { seen.add(v.vod_id); list.push(v); }
        return { list };
    },
    category(tid, pg, filter, extend = {}) {
        const page = Math.max(parseInt(pg, 10) || 1, 1);
        const value = key => extend[key] || '*';
        if (['type', 'region', 'state', 'filter'].every(k => value(k) === '*')) {
            let list = [];
            if (tid === 'hot') list = hot(get(SITE + '/'), 0);
            else if (tid === 'hot_cn') list = hot(get(SITE + '/'), 1);
            else if (tid === 'recent') {
                const $ = parseHTML(get(SITE + '/today'));
                const seen = new Set();
                $('.today .hot-search__content > a[href^="/detail/"]').each((_, a) => {
                    const id = ($(a).attr('href') || '').slice(8).trim();
                    const keyword = $(a).find('.hot-search-item__keyword').first();
                    const name = keyword.length ? keyword.contents().filter((__, n) => n.type === 'text').text().trim() : '';
                    if (!id || !name || seen.has(id)) return;
                    seen.add(id);
                    const img = $(a).find('amp-img, img').first();
                    list.push({ vod_id: id, vod_name: name, vod_pic: (img.attr('src') || '').trim(), vod_remarks: join(' ', [textOf($(a).find('em').first()), textOf($(a).find('.hot-search-item__right').first())]) });
                });
            }
            return { page: 1, pagecount: 1, limit: list.length, total: list.length, list };
        }
        const url = `${SITE}/api/amp_query_cartoon_list?type=${encodeURIComponent(value('type'))}&region=${encodeURIComponent(value('region'))}&filter=${encodeURIComponent(value('state'))}&filter=${encodeURIComponent(value('filter'))}&page=${page}&limit=36&language=cn`;
        const data = JSON.parse(get(url) || '{}');
        const list = (data.items || []).filter(i => i.cartoon_id && i.name).map(i => ({
            vod_id: i.cartoon_id, vod_name: i.name, vod_pic: i.topic_img ? 'https://static-a.xgcartoon.com/cover/' + i.topic_img : '',
            vod_remarks: join(' ', [i.author || i.region_name, join('/', (i.type_names || []).slice(0, 2))])
        }));
        const more = data.next != null && String(data.next) !== '';
        return { page, pagecount: more ? page + 1 : page, limit: 36, total: more ? 2147483647 : (page - 1) * 36 + list.length, list };
    },
    detail(id) {
        const html = get(`${SITE}/detail/${id}`);
        const $ = parseHTML(html);
        const author = textOf($('.detail-right__title > div').first());
        const episodes = [], seen = new Set();
        $('a.goto-chapter[title][href^="/user/page_direct?"]').each((_, a) => {
            const href = $(a).attr('href') || '';
            if (!href || seen.has(href)) return;
            seen.add(href);
            episodes.push(`${($(a).attr('title') || '').replace(/[#$]/g, '_').trim() || '播放'}$${href}`);
        });
        if (!episodes.length) { const vid = vidOf(html); if (vid) episodes.push('播放$' + playlist(vid)); }
        return { list: [{
            vod_id: id, vod_name: textOf($('h1.h1').first()), vod_pic: ($('amp-img[src*="cover/"], img[src*="cover/"]').first().attr('src') || '').trim(),
            type_name: join(' / ', $('.tag').toArray().map(t => textOf($(t)))), vod_remarks: author, vod_actor: author,
            vod_content: textOf($('.detail-right__desc p').first()), vod_play_from: '西瓜卡通', vod_play_url: episodes.join('#')
        }] };
    },
    search(wd) {
        const $ = parseHTML(get(`${SITE}/search?q=${encodeURIComponent(wd)}`));
        const list = [], seen = new Set();
        $('a.topic-list-item[href^="/detail/"]').each((_, a) => {
            const id = ($(a).attr('href') || '').slice(8).trim(), name = textOf($(a).find('.h3').first());
            if (!id || !name || seen.has(id)) return;
            seen.add(id);
            const tags = join('/', $(a).find('.tag').toArray().slice(0, 2).map(t => textOf($(t))));
            list.push({ vod_id: id, vod_name: name, vod_pic: ($(a).find('amp-img[src*="cover/"], img[src*="cover/"]').first().attr('src') || '').trim(), vod_remarks: join(' ', [textOf($(a).find('.topic-list-item--author').first()), tags]) });
        });
        return { list };
    },
    play(flag, id) {
        if (id.startsWith('http') && id.includes('.m3u8')) return { parse: 0, url: id, header: headers(FRAME + '/'), format: 'application/x-mpegURL' };
        const page = id.startsWith('http') ? id : SITE + id;
        const vid = vidOf(get(page));
        if (!vid) return { parse: 1, url: page, header: headers(SITE + '/') };
        return { parse: 0, url: playlist(vid), header: headers(FRAME + '/'), format: 'application/x-mpegURL' };
    }
};
