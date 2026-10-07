// NiuLai family (素笺, 云岫, 星澜, 茶寮, 竹隐, 玉阶, 香篆, 松庭, 纸鸢, 墨砚): every call runs through the
// author's niulai.php bridge, which signs and decodes the upstream app API server-side.
// ext: {"php": "https://.../niulai.php", "site": "<name>"}
import { Bridge, b64url, unb64url, mediaLooksValid, bridgeFilters, bridgeVideos, bridgePage } from './_bridge.js';

const KEY = 'R7uK3mP9xV2bN5qL';
const IV = 'T4gH8jS1dF6aZ0cW';
const ACCESS = ['NlBridgeAccess', 'cfe5cf91398c417e42c1d57c09804244903833e63b3aff7f'];
const SDK = 28;

let bridge;
let playname = '';
const contexts = new Map();  // "line\nurl" -> { name, playUrl, episodes }

const episodeName = name => String(name || '').replace(/[#$]/g, ' ').trim() || '播放';

function parseEpisode(id) {
    if (String(id).startsWith('smtv:')) {
        const parts = id.slice(5).split(':');
        if (parts.length >= 3) return { title: unb64url(parts[1]), line: unb64url(parts[0]), url: unb64url(parts.slice(2).join(':')) };
        if (parts.length === 2) return { title: '', line: unb64url(parts[0]), url: unb64url(parts[1]) };
    }
    return { title: '', line: '', url: String(id || '') };
}

const ORDINALS = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];

function lineNames(names) {
    // The plugin names lines "<playname><ordinal>线[quality]" when the bridge supplies a playname.
    if (!playname) return names;
    return names.map((name, index) => {
        const quality = (name.match(/\[[^\]]+\]|4K|1080P?|720P?|蓝光|超清|高清/i) || [''])[0];
        const tag = quality ? (quality.startsWith('[') ? quality : `[${quality}]`) : '';
        return `${playname}${ORDINALS[index] || index + 1}线${tag}`;
    });
}

function detailItem(id, result) {
    const vod = result.vod || {};
    const sources = Array.isArray(result.sources) ? result.sources : (Array.isArray(vod.video_list) ? vod.video_list : []);
    const names = [], urls = [], episodes = [];
    for (const source of sources) {
        const items = [];
        for (const episode of (source && source.episodes) || []) {
            const url = String(episode.url || '').trim();
            if (!url || url === '*') continue;
            const title = episodeName(episode.name);
            const line = String(episode.line || '').trim();
            items.push(`${title}$smtv:${b64url(line)}:${b64url(title)}:${b64url(url)}`);
            episodes.push({ title, line, url });
        }
        if (items.length) { names.push(String(source.name || '').trim() || `线路${names.length + 1}`); urls.push(items.join('#')); }
    }
    const item = {
        vod_id: String(vod.id || id), vod_name: String(vod.name || ''), vod_pic: String(vod.pic || ''), vod_remarks: String(vod.remarks || ''),
        vod_year: String(vod.year || ''), vod_area: String(vod.area || ''), type_name: String(vod.type || ''), vod_actor: String(vod.actor || ''),
        vod_director: String(vod.director || ''), vod_content: String(vod.content || '')
    };
    if (urls.length) { item.vod_play_from = lineNames(names).join('$$$'); item.vod_play_url = urls.join('$$$'); }
    for (const episode of episodes) contexts.set(episode.line + '\n' + episode.url, { name: item.vod_name, episodes });
    return item;
}

function candidates(episode) {
    const context = contexts.get(episode.line + '\n' + episode.url) || [...contexts.values()].find(c => c.episodes.some(e => e.url === episode.url));
    const list = [episode];
    if (context && episode.title) for (const other of context.episodes) if (other.title === episode.title && (other.url !== episode.url || other.line !== episode.line)) list.push(other);
    return { name: context ? context.name : '', list };
}

export default {
    init(ext) {
        let config = ext;
        if (typeof config === 'string') config = JSON.parse(config.trim());
        const php = String(config.php || '').trim().replace(/\/+$/, '');
        const site = String(config.site || '').trim();
        if (!/^https?:\/\//.test(php) || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(site)) throw new Error('NiuLai ext requires php and site');
        bridge = new Bridge({ php, site, key: KEY, iv: IV, access: ACCESS, label: 'niulai_' + site, onMeta: meta => { if (meta.playname) playname = String(meta.playname).trim(); } });
    },
    home(filter) {
        bridge.ensure();
        const result = bridge.call('home', { filter: !!filter, sdk: SDK });
        const classes = (result.classes || []).filter(c => c && String(c.id || '').trim() && String(c.name || '').trim()).map(c => ({ type_id: String(c.id).trim(), type_name: String(c.name).trim() }));
        return { class: classes, list: bridgeVideos(result.list), filters: bridgeFilters(result.filters) };
    },
    category(tid, pg, filter, extend = {}) {
        bridge.ensure();
        const page = Math.max(1, parseInt(pg, 10) || 1);
        return bridgePage(page, bridge.call('category', { tid: String(tid || ''), page, extend: { ...extend }, sdk: SDK }));
    },
    detail(id) {
        bridge.ensure();
        return { list: [detailItem(id, bridge.call('detail', { id, sdk: SDK }))] };
    },
    search(wd, quick, pg) {
        bridge.ensure();
        const page = Math.max(1, parseInt(pg, 10) || 1);
        return bridgePage(page, bridge.call('search', { keyword: String(wd || ''), page, sdk: SDK }));
    },
    play(flag, id) {
        bridge.ensure();
        const episode = parseEpisode(id);
        const { name, list } = candidates(episode);
        const deadline = Date.now() + 45000;  // the host stops a call at 60 s
        let failure;
        for (let pass = 0; pass < 2; pass++) {
            for (let index = 0; index < list.length; index++) {
                if (Date.now() > deadline) throw new Error('播放线路响应超时，请稍后重试或切换线路');
                const candidate = list[index];
                try {
                    const answer = bridge.call('player', { flag: flag || '', url: candidate.url, line: candidate.line, title: candidate.title, vodname: name, sdk: SDK, force_session: pass > 0 && index === 0 });
                    const url = String(answer.url || '').trim();
                    if (!/^https?:\/\//.test(url)) throw new Error('PLAY_URL_EMPTY');
                    const header = {};
                    for (const [k, v] of Object.entries(answer.header || {})) if (k && v) header[k] = String(v);
                    const type = Number(answer.type) || 0;
                    if (type === 0 && !mediaLooksValid(url, header)) throw new Error('SOURCE_EXPIRED');
                    const result = { parse: type === 0 ? 0 : 1, url, header };
                    if (url.toLowerCase().includes('.m3u8')) result.format = 'application/x-mpegURL';
                    return result;
                } catch (error) { failure = error; }
            }
        }
        throw failure || new Error('NiuLai playback candidates empty');
    }
};
