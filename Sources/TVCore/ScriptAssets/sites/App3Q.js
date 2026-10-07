// App3Q family (三秋, 马猴): the author's app3q.php bridge (same keys as App88) drives the upstream API.
// ext: "https://.../app3q.php?site=<name>"
import { Bridge } from './_bridge.js';
import { randomHex } from './_lite.js';

const KEY = 'XyeDA1uF8x3WcIeE';
const IV = 'ohkb6oSM7yyZKZzo';
const ACCESS = ['FGAjpziyjdOV', '27f682b57aaf58c78e8c09cd22b34e324919470b25958322'];

let bridge;
let device = '';

function sleep(ms) { const until = Date.now() + Math.min(ms, 5000); while (Date.now() < until) { /* synchronous */ } }

function call(scene, params = {}) {
    let state = null;
    for (let round = 0; round < 4; round++) {
        const prepared = bridge.send({ action: 'prepare', scene, params, client_time_ms: Date.now(), device_id: device, state });
        if (prepared.terminal && prepared.result) return prepared.result;
        const ticket = String(prepared.ticket || '');
        if (!prepared.request || !ticket) throw new Error('App3Q准备结果无效');
        if ('state' in prepared) state = prepared.state;
        if (String(prepared.request.method || '').toUpperCase() !== 'GET') throw new Error('App3Q仅允许GET目标请求');
        const reply = bridge.perform({ ...prepared.request, method: 'GET' });
        const consumed = bridge.send({ action: 'consume', scene, params, ticket, status: reply.status, headers: reply.headers, body: reply.body, state });
        if (consumed.result) return consumed.result;
        if (consumed.terminal) throw new Error('App3Q终止结果为空');
        if (!consumed.next) throw new Error('App3Q响应结果无效');
        if ('state' in consumed) state = consumed.state;
        if (Number(consumed.delay_ms) > 0) sleep(Number(consumed.delay_ms));
    }
    throw new Error('App3Q请求链过长');
}

const label = text => String(text || '').replace(/[#$]/g, ' ').trim() || '播放';
const videos = list => (Array.isArray(list) ? list : []).filter(v => v && v.id && v.name)
    .map(v => ({ vod_id: String(v.id), vod_name: String(v.name), vod_pic: String(v.pic || ''), vod_remarks: String(v.remarks || '') }));

function page(pg, result) {
    const list = videos(result.list);
    const current = Math.max(1, Number(result.page) || pg);
    return { page: current, pagecount: Math.max(1, Number(result.pagecount) || current), limit: Math.max(1, Number(result.limit) || 20), total: Math.max(Number(result.total) || 0, list.length), list };
}

export default {
    init(ext) {
        const address = String(ext || '').trim();
        if (!/^https?:\/\//.test(address)) throw new Error('App3Q服务地址未配置');
        device = randomHex(8);
        bridge = new Bridge({ php: address, site: '', key: KEY, iv: IV, access: ACCESS, label: 'app3q' });
    },
    home() {
        const result = call('home');
        const classes = (result.classes || []).filter(c => c && c.id && c.name).map(c => ({ type_id: String(c.id), type_name: String(c.name) }));
        return { class: classes, list: videos(result.list) };
    },
    category(tid, pg) {
        const p = Math.max(1, parseInt(pg, 10) || 1);
        return page(p, call('category', { tid: String(tid || ''), page: p }));
    },
    detail(id) {
        const result = call('detail', { id });
        const vod = result.vod;
        if (!vod) return { list: [] };
        const names = [], urls = [];
        for (const source of result.sources || []) {
            const episodes = (source.episodes || []).filter(e => e && e.play_id).map(e => label(e.name) + '$' + e.play_id);
            if (episodes.length) { names.push(String(source.name || '').trim() ? label(source.name) : `线路${names.length + 1}`); urls.push(episodes.join('#')); }
        }
        return { list: [{
            vod_id: String(vod.id || id), vod_name: String(vod.name || ''), vod_pic: String(vod.pic || ''), type_name: String(vod.type || ''),
            vod_remarks: String(vod.remarks || ''), vod_actor: String(vod.actor || ''), vod_director: String(vod.director || ''),
            vod_content: String(vod.content || '').replace(/[\r\n]+/g, '').trim(), vod_play_from: names.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search(wd, quick, pg) {
        const p = Math.max(1, parseInt(pg, 10) || 1);
        return page(p, call('search', { key: String(wd || ''), page: p }));
    },
    play(flag, id) {
        const url = String(call('play', { play_id: id }).url || '').trim();
        if (!/^https?:\/\//.test(url)) return { parse: 0, url: '' };
        const result = { parse: 0, url };
        if (url.toLowerCase().includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
