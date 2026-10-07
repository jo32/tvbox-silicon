// 看球 (csp_Kanqiu): live sports listings; each match's "<page>-url" endpoint returns base64 links.
// Links are web players, so playback asks the app's sniffer (parse=1) like the original spider.
// ext: "http://www.88kanqiu.one"
import { parseHTML, textOf } from './_lite.js';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
const FILTERS = JSON.parse('{"1":[{"key":"cateId","name":"类型","value":[{"n":"NBA","v":"1"},{"n":"CBA","v":"2"},{"n":"WNBA","v":"20"},{"n":"篮球综合","v":"4"}]}],"8":[{"key":"cateId","name":"类型","value":[{"n":"英超","v":"8"},{"n":"西甲","v":"9"},{"n":"意甲","v":"10"},{"n":"德甲","v":"14"},{"n":"法甲","v":"15"},{"n":"欧冠","v":"12"},{"n":"欧联","v":"13"},{"n":"中超","v":"7"},{"n":"亚冠","v":"11"},{"n":"足总杯","v":"27"},{"n":"美职联","v":"26"},{"n":"中甲","v":"31"},{"n":"足球综合","v":"23"}]}],"21":[{"key":"cateId","name":"类型","value":[{"n":"体育电视台","v":"21"},{"n":"网球","v":"29"},{"n":"NFL","v":"25"},{"n":"羽毛球","v":"19"},{"n":"棒球","v":"38"}]}]}');
const DEFAULT_PIC = 'https://pic.imgdb.cn/item/657673d6c458853aeff94ab9.jpg';

let site = 'https://www.88kanqiu.one';

function normalize(address) {
    const colon = address.indexOf(':');
    const scheme = colon > 0 ? address.slice(0, colon) : 'https';
    return scheme + '://' + (colon > 0 ? address.slice(Math.min(colon + 3, address.length)) : address).replace(/\/+$/, '');
}

const get = url => { try { return globalThis.req(url, { headers: { 'User-Agent': UA } }).content || ''; } catch { return ''; } };

export default {
    init(ext) { if (ext) site = normalize(String(ext)); },
    home() {
        return { class: [['', '全部直播'], ['1', '篮球直播'], ['8', '足球直播'], ['21', '其他直播']].map(([type_id, type_name]) => ({ type_id, type_name })), filters: FILTERS };
    },
    category(tid, pg, filter, extend = {}) {
        const id = extend.cateId || tid;
        const $ = parseHTML(get(site + (id ? `/match/${id}/live` : '')));
        const items = $('.list-group-item');
        const list = items.toArray().map(item => {
            const button = $(item).find('.btn.btn-primary').first();
            let image = $(item).find('.col-xs-1').first().find('img').first().attr('src') || DEFAULT_PIC;
            if (!image.startsWith('http')) image = site + image;
            return { vod_id: site + (button.attr('href') || ''), vod_name: textOf($(item).find('.row.d-none').first()) || textOf($(item)), vod_pic: image, vod_remarks: textOf(button) };
        });
        return { page: 1, pagecount: 1, limit: 0, total: items.length, list };
    },
    detail(id) {
        if (id === site) return { list: [], msg: '比赛尚未开始' };
        const data = String(JSON.parse(get(id + '-url') || '{}').data || '');
        const encoded = data.slice(6, data.length - 2);
        const links = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8')).links || [];
        return { list: [{ vod_id: id, vod_play_from: 'Qile', vod_play_url: links.map(l => `${l.name}$${String(l.url).replace(/#/g, '***')}`).join('#') }] };
    },
    search() { return { list: [] }; },
    play(flag, id) { return { parse: 1, url: String(id).replace(/\*\*\*/g, '#'), header: { 'User-Agent': UA } }; }
};
