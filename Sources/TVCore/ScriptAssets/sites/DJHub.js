// 短剧聚合 (csp_DJHub): six short-drama apps behind one site. Video ids are "<source>@<id>".
//   七猫  api-store.qmplaylet.com, md5-signed query + qm-params header (base64 with a substituted alphabet)
//   星芽  app.whjzjx.cn, device login token
//   西饭  xifan-api-cn.youlishipin.com
//   围观  api.drama.9ddm.com
//   河马  www.kuaikaw.cn pages (__NEXT_DATA__)
//   好看  sv.baidu.com haokan playlet APIs; episodes resolve per clarity at play time
import { md5, formBody } from './_lite.js';

const QM_SALT = 'd3dGiJc651gSQ8w1';
const QM_STORE = 'https://api-store.qmplaylet.com', QM_READ = 'https://api-read.qmplaylet.com';
const XY = 'https://app.whjzjx.cn', XIFAN = 'https://xifan-api-cn.youlishipin.com', WG = 'https://api.drama.9ddm.com/drama/home';
const HEMA = 'https://www.kuaikaw.cn', BAIDU = 'https://sv.baidu.com';
const OKHTTP = { 'User-Agent': 'okhttp/3.12.11', 'Content-Type': 'application/json; charset=utf-8' };
const WG_HEADERS = { 'User-Agent': 'okhttp/5.1.0', 'Content-Type': 'application/json; charset=utf-8' };
const BAIDU_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 11; M2012K10C Build/RP1A.200720.011; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/87.0.4280.141 Mobile Safari/537.36 haokan/7.80.0.18 (Baidu; P1 11)/imoaiX_03_11_C01K2102M/1043677m/5ACDB023CFB9D64743B08E51953F7C76%7CVSAJ32AVA/1/7.80.0.18/780001/1/immersiveMode/modeV4PlusWhite/isFirstInstall/bbqMode/bbqModeV2/blackStyle/isPlaylet Talos/1.8.7',
    'Content-Type': 'application/x-www-form-urlencoded', 'Talos-Module-Name': 'shortDrama', 'Talos-Module-Version': '1.0.71.1',
    Cookie: 'BAIDUCUID=giHCu0azv80G8SfQ0avU8gaaH8jfiv86ju2MugiR2i8-k3a35avAa1_mA'
};
const BAIDU_PLAY_UA = 'Mozilla/5.0 (Linux; Android 4.4.2; Nexus 5 Build/KOT49H) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/30.0.0.0 Mobile Safari/537.36 dumedia/7.74.1.3';
const SOURCES = [['围观', '围观短剧'], ['河马', '河马短剧'], ['好看', '好看短剧'], ['七猫', '七猫短剧'], ['星芽', '星芽短剧'], ['西饭', '西饭短剧']];

const enc = s => encodeURIComponent(s == null ? '' : String(s));
const str = (o, k, d = '') => o && o[k] != null && String(o[k]) !== 'null' && String(o[k]) !== '' ? String(o[k]) : d;
const vod = (vod_id, vod_name, vod_pic, vod_remarks) => ({ vod_id, vod_name: String(vod_name || ''), vod_pic: String(vod_pic || ''), vod_remarks: String(vod_remarks || '') });
const result = (list, page, pagecount, limit, total) => ({ list, page, pagecount, limit, total });
const parse = text => { try { return text && String(text).trim() ? JSON.parse(text) : {}; } catch { return {}; } };
const getJSON = (url, headers) => parse(globalThis.req(url, { headers, timeout: 15000 }).content);
const postJSON = (url, headers, body) => parse(globalThis.req(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body), timeout: 15000 }).content);
const baidu = (path, body) => parse(globalThis.req(BAIDU + path, { method: 'POST', headers: BAIDU_HEADERS, body, timeout: 15000 }).content);
function browser(referer) {
    return { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36', Referer: referer,
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8', 'Content-Type': 'application/json' };
}
function nextData(url) {
    const html = String(globalThis.req(url, { headers: browser(url), timeout: 15000 }).content || '');
    const m = html.match(/<script[^>]*id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
    return { html, data: m ? parse(m[1]) : {} };
}
const mp4Of = o => o ? str(o, 'mp4') || str(o, 'mp4720p') || str(o, 'vodMp4Url') : '';

// 七猫: headers carry a base64 device blob (alphabet substituted) signed with md5.
let qmHeaders = null, qmAt = 0;
function qm() {
    const now = Date.now();
    if (qmHeaders && now - qmAt < 300000) return qmHeaders;
    const device = { static_score: '0.8', uuid: '00000000-7fc7-08dc-0000-000000000000', 'device-id': '20250220125449b9b8cac84c2dd3d035c9052a2572f7dd0122edde3cc42a70',
        sourceuid: 'aa7de295aad621a6', 'refresh-type': '0', model: '22021211RC', 'client-id': 'aa7de295aad621a6', brand: 'Redmi', 'sys-ver': '12', 'phone-level': 'H',
        'wlb-uid': 'aa7de295aad621a6', 'session-id': String(now) };
    const from = '+/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', to = 'PXMUlErYWbdJ9saI0oy_HGitgNA8Fk3hfRqC4pmBOuc6Kx5T-2zSZ1VvjQ7DwnLe';
    const params = [...Buffer.from(JSON.stringify(device), 'utf8').toString('base64')].map(c => { const i = from.indexOf(c); return i < 0 ? c : to[i]; }).join('');
    const sign = md5(`AUTHORIZATION=app-version=10001application-id=com.duoduo.readchannel=unknownis-white=net-env=5platform=androidqm-params=${params}reg=${QM_SALT}`);
    qmHeaders = { 'net-env': '5', reg: '', channel: 'unknown', 'is-white': '', platform: 'android', 'application-id': 'com.duoduo.read', authorization: '', 'app-version': '10001', 'User-Agent': 'webviewversion/0', 'qm-params': params, sign };
    qmAt = now;
    return qmHeaders;
}

// 星芽: a device login yields the bearer token.
let xyHeaders = null;
function xy() {
    if (xyHeaders && xyHeaders.authorization) return xyHeaders;
    const login = postJSON('https://u.shytkjgs.com/user/v1/account/login', { ...OKHTTP, platform: '1' }, { device: '24250683a3bdb3f118dff25ba4b1cba1a' });
    const token = str(login.data, 'token') || str(login, 'token');
    xyHeaders = { ...OKHTTP };
    if (token) xyHeaders.authorization = token;
    return xyHeaders;
}
const xyCard = o => o && str(o, 'id') ? vod('星芽@' + str(o, 'id'), o.title, o.cover_url, str(o, 'total') + '集') : null;

// 围观: every request carries a random clientInfo.
function wgQuery() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let random = '';
    for (let i = 0; i < 10; i++) random += chars[Math.floor(Math.random() * 62)];
    return '?version_code=1600&version_name=1.6.0&device_name=Android&device_type=phone&is_first_day=true&is_first_24h=true&app_launch_way=icon&default_homepage=homepage_interaction&device_owning_firm=Android&font_scale=default&os_type=1&clientInfo=' + enc(Buffer.from(random, 'utf8').toString('base64'));
}
const wgCards = list => (list || []).filter(o => o && str(o, 'oneId')).map(o => vod('围观@' + str(o, 'oneId'), o.title, str(o, 'horzPoster') || str(o, 'vertPoster'), str(o, 'episodeCount') + '集'));

function xifanCards(category, data) {
    const list = [];
    for (const element of ((data.result || {}).elements || []).filter(Boolean)) {
        const contents = element.contents || (element.duanjuVo ? [element] : []);
        for (const content of contents) {
            const d = content && content.duanjuVo;
            if (!d || !str(d, 'duanjuId')) continue;
            if (category && !(d.categories || []).map(String).includes(category)) continue;
            list.push(vod(`西饭@${str(d, 'duanjuId')}#${str(d, 'source')}`, d.title, d.coverImageUrl, str(d, 'total') + '集'));
            if (!category) break;
        }
    }
    return list;
}
const hemaCards = list => (list || []).filter(o => o && str(o, 'bookId')).map(o => vod('河马@/drama/' + str(o, 'bookId'), o.bookName, o.coverWap, `${str(o, 'statusDesc')} ${str(o, 'totalChapterNum')}集`.trim()));
const haokanCards = list => (list || []).filter(o => o && str(o, 'playlet_id')).map(o => vod('好看@' + str(o, 'playlet_id'), o.playlet_title, o.playlet_poster, o.episodes_num_text));

let shelf = null, shelfAt = 0;
function haokanShelf() {
    if (shelf && Date.now() - shelfAt < 300000) return shelf;
    shelf = baidu('/haokan/ui-feed/playletShelfFeed?osbranch=a0', 'from=feed').data || {};
    shelfAt = Date.now();
    return shelf;
}
function haokanVideo(playlet, vid) {
    const body = `method=post&vid=${vid}&immersive_mode=v4_5&tplname=feed_small_video&tag=playlet_talos&tab=detail&external_from=&is_dp_video=0&immersive_square_type=3&video_set_id=${playlet}&play_screen_type=1&play_volume_type=2&play_external_device_type=1`;
    return ((baidu('/appui/api?osbranch=a0', 'video/relate=' + enc(body))['video/relate'] || {}).data || {}).cur_video || {};
}

const group = (key, name, ...pairs) => { const value = []; for (let i = 0; i + 1 < pairs.length; i += 2) value.push({ n: pairs[i], v: pairs[i + 1] }); return { key, name, value }; };

const category = {
    七猫(page, ext) {
        if (page > 1) return result([], page, 1, 0, 0);
        const tag = ext.area ?? '0';
        const data = getJSON(`${QM_STORE}/api/v1/playlet/index?tag_id=${enc(tag)}&playlet_privacy=1&operation=1&sign=${md5(`operation=1playlet_privacy=1tag_id=${tag}${QM_SALT}`)}`, qm()).data || {};
        const list = (data.list || []).filter(o => o && str(o, 'playlet_id')).map(o => vod('七猫@' + str(o, 'playlet_id'), o.title, o.image_link, str(o, 'total_episode_num') + '集'));
        return result(list, page, 1, list.length, list.length);
    },
    星芽(page, ext) {
        const theater = ext.area ?? '1', class2 = ext.class2 ?? '0', rank = ext.rank ?? '1';
        let data;
        if (theater !== '9') data = getJSON(`${XY}/cloud/v2/theater/home_page?theater_class_id=${enc(theater)}&type=1&class2_ids=${enc(class2)}&page_num=${page}&page_size=24`, xy()).data;
        else if (page > 1) return result([], page, 1, 0, 0);
        else data = getJSON(`${XY}/cloud/v1/first_level_ranking/detail?id=${enc(rank)}`, xy()).data;
        const list = ((data || {}).list || []).map(o => xyCard(o && o.theater ? o.theater : o)).filter(Boolean);
        return result(list, page, list.length < 24 ? page : page + 1, 24, list.length);
    },
    西饭(page, ext) {
        if (page > 1) return result([], page, 1, 0, 0);
        const area = ext.area ?? '都市';
        const list = xifanCards(area, getJSON(`${XIFAN}/xifan/search/getSearchList?reqType=search&offset=0&keyword=${enc(area)}&quickEngineVersion=-1&scene=`, OKHTTP));
        return result(list, page, 1, list.length, list.length);
    },
    围观(page, ext) {
        const body = { audience: '全部', order: '最新', page, pageSize: 30, searchWord: '', subject: ext.area ?? '' };
        const list = wgCards(postJSON(`${WG}/search${wgQuery()}`, WG_HEADERS, body).data);
        return result(list, page, list.length < 30 ? page : page + 1, 30, list.length);
    },
    河马(page, ext) {
        const tag = ext.area ?? '462';
        const props = (nextData(`${HEMA}/browse/${enc(tag)}/${page}`).data.props || {}).pageProps || {};
        const list = hemaCards(props.bookList);
        const pages = Math.max(page, Number(props.pages) || page);
        return result(list, page, pages, list.length, Math.max(1, list.length) * pages);
    },
    好看(page, ext) {
        const tag = ext.area ?? '';
        let list;
        if (!tag) list = page === 1 ? haokanCards(haokanShelf().playlet_banner) : [];
        else list = haokanCards((baidu('/haokan/ui-feed/playletTagsFeed?osbranch=a0', formBody({ tag_id: tag, pn: String(page), rn: '9' })).data || {}).list);
        return result(list, page, list.length < 9 ? page : page + 1, 9, list.length);
    }
};

const search = {
    七猫(page, wd) {
        const sign = md5(`extend=page=${page}read_preference=0track_id=ec1280db127955061754851657967wd=${wd}${QM_SALT}`);
        const data = getJSON(`${QM_STORE}/api/v1/playlet/search?extend=&page=${page}&wd=${enc(wd)}&read_preference=0&track_id=ec1280db127955061754851657967&sign=${sign}`, qm()).data || {};
        return (data.list || []).filter(o => o && str(o, 'id')).map(o => vod('七猫@' + str(o, 'id'), String(o.title || '').replace(/<[^>]*>/g, '').trim(), o.image_link, `七猫短剧｜${str(o, 'total_num')}集`));
    },
    星芽(page, wd) {
        const data = postJSON(`${XY}/v3/search`, xy(), { text: wd }).data || {};
        const list = (data.theater && data.theater.search_data) || data.search_data || data.list || [];
        return list.map(o => { const card = xyCard(o); if (card) card.vod_remarks = `星芽短剧｜${str(o, 'total')}集`; return card; }).filter(Boolean);
    },
    西饭(page, wd) { return xifanCards('', getJSON(`${XIFAN}/xifan/search/getSearchList?reqType=search&offset=${(page - 1) * 30}&keyword=${enc(wd)}&quickEngineVersion=-1&scene=`, OKHTTP)); },
    围观(page, wd) { return wgCards(postJSON(`${WG}/search${wgQuery()}`, WG_HEADERS, { audience: '', order: '', page, pageSize: 30, searchWord: wd, subject: '' }).data); },
    河马(page, wd) {
        const pname = HEMA.replace(/^https?:\/\//, '');
        const headers = { ...browser(`${HEMA}/search?searchValue=${enc(wd)}`), Origin: HEMA, pname, tmpid: Buffer.from(String(Math.random())).toString('hex').slice(0, 16) };
        return hemaCards((postJSON(`${HEMA}/seo/video/6007`, headers, { sourceType: 1, keyword: wd, index: page, page }).data || {}).bookList);
    },
    好看(page, wd) {
        return (baidu('/haokan/ui-interact/playlet/search/sugs?osbranch=a0', 'search_word=' + wd).data || []).filter(o => o && str(o, 'id')).map(o => vod('好看@' + str(o, 'id'), o.title, o.cover_url, '好看短剧'));
    }
};

const detail = {
    七猫(full, id) {
        const d = getJSON(`${QM_READ}/player/api/v1/playlet/info?playlet_id=${enc(id)}&sign=${md5(`playlet_id=${id}${QM_SALT}`)}`, qm()).data;
        if (!d) throw new Error('empty');
        const eps = (d.play_list || []).filter(e => e && str(e, 'video_url')).map((e, i) => `${str(e, 'sort', String(i + 1))}$${str(e, 'video_url')}`);
        return { ...vod(full, d.title, d.image_link, `${Number(d.total_episode_num) || 0}集`), vod_content: str(d, 'intro'), vod_play_from: '七猫短剧', vod_play_url: eps.join('#') };
    },
    星芽(full, id) {
        const d = getJSON(`${XY}/v2/theater_parent/detail?theater_parent_id=${enc(id)}`, xy()).data;
        if (!d) throw new Error('empty');
        const eps = (d.theaters || []).filter(e => e && str(e, 'son_video_url')).map((e, i) => `${str(e, 'num', String(i + 1))}$${str(e, 'son_video_url')}`);
        return { ...vod(full, d.title, d.cover_url, d.desc_tags), vod_play_from: '星芽短剧', vod_play_url: eps.join('#') };
    },
    西饭(full, id) {
        const [duanju, source] = id.split('#');
        if (source == null) throw new Error('bad Xifan id');
        const d = getJSON(`${XIFAN}/xifan/drama/getDuanjuInfo?duanjuId=${enc(duanju)}&source=${enc(source)}`, OKHTTP).result;
        if (!d) throw new Error('empty');
        const eps = (d.episodeList || []).filter(e => e && str(e, 'playUrl')).map((e, i) => `${str(e, 'index', String(i + 1))}$${str(e, 'playUrl')}`);
        return { ...vod(full, d.title, d.coverImageUrl, `${Number(d.total) || 0}集 ${d.updateStatus === 'over' ? '已完结' : '更新中'}`), vod_play_from: '西饭短剧', vod_play_url: eps.join('#') };
    },
    围观(full, id) {
        const data = getJSON(`${WG}/shortVideoDetail${wgQuery()}&oneId=${enc(id)}&page=1&pageSize=1000&userId=0&queryAll=true`, WG_HEADERS);
        const episodes = (data.data || []).filter(Boolean);
        const lines = new Map();
        episodes.forEach((e, i) => {
            for (const c of e.videoClarityList || []) {
                if (!c || !str(c, 'url')) continue;
                const name = str(c, 'name', '默认');
                if (!lines.has(name)) lines.set(name, []);
                lines.get(name).push(`${str(e, 'playOrder', String(i + 1))}$围观@${str(c, 'url')}`);
            }
        });
        const first = episodes[0];
        return { ...vod(full, str(data, 'title') || str(first, 'title'), str(data, 'vertPoster') || str(first, 'vertPoster'), `共${episodes.length}集`),
            vod_content: str(data, 'description'), vod_play_from: [...lines.keys()].join('$$$'), vod_play_url: [...lines.values()].map(l => l.join('#')).join('$$$') };
    },
    河马(full, id) {
        const path = id.startsWith('/drama/') ? id : '/drama/' + id;
        const props = (nextData(HEMA + path).data.props || {}).pageProps;
        if (!props) throw new Error('empty Hema detail');
        const book = props.bookInfoVo || {};
        const bookId = path.replace('/drama/', '');
        const eps = (props.chapterList || []).filter(Boolean).map((c, i) => `${str(c, 'chapterName', String(i + 1))}$${mp4Of(c.chapterVideoVo) || `${bookId}+${str(c, 'chapterId')}`}`);
        return { ...vod(full, str(book, 'title') || str(book, 'bookName'), book.coverWap, `${str(book, 'statusDesc')} ${str(book, 'totalChapterNum')}集`.trim()),
            vod_content: str(book, 'introduction'), vod_play_from: '河马短剧', vod_play_url: eps.join('#') };
    },
    好看(full, id) {
        const list = `enable_enter_playlet=0&seek_time=0&hotspot=0&auto_show_hot_point_panel=0&type=playlet&commonlist_id=${Date.now()}&scene=&vid=&enable_atlas=0&mark_pn=&uk=&ctime=0&from=playlet_new&id=${id}&rn=10&pn=1&direction=3`;
        const first = baidu('/appui/api?osbranch=a0', 'video/commonlist=' + enc(list))['video/commonlist'].data.results[0].content;
        const d = baidu('/haokan/ui-video/playlet/rec/detail?osbranch=a0', formBody({ playlet_id: id, vid: str(first, 'vid') })).data;
        const vids = (d.vid_list || []).map(String);
        const eps = vids.map((vid, i) => `第${i + 1}集$${id}@${vid}`).join('#');
        const clarities = [];
        if (vids.length) {
            const video = haokanVideo(id, vids[0]);
            for (const c of [...(video.clarityUrl || [])].reverse()) { const title = str(c, 'title'); if (title && !clarities.includes(title)) clarities.push(title); }
            for (const name of Object.keys(video.video_list || {})) if (name && !clarities.includes(name)) clarities.push(name);
        }
        if (!clarities.length) clarities.push('默认');
        return { ...vod(full, d.playlet_title, d.playlet_poster, d.hot_value), vod_content: str(d, 'description'), vod_play_from: clarities.join('$$$'), vod_play_url: clarities.map(() => eps).join('$$$') };
    }
};

function playHaokan(flag, id) {
    const [playlet, vid] = id.split('@');
    if (vid == null) return { parse: 0, url: '', msg: '解析失败' };
    const video = haokanVideo(playlet, vid);
    const clarities = video.clarityUrl || [];
    const chosen = clarities.find(c => c && (str(c, 'title').includes(flag) || flag.includes(str(c, 'title'))));
    let url = chosen ? str(chosen, 'url') : '';
    if (!url && clarities.length) url = str(clarities[clarities.length - 1], 'url');
    const list = video.video_list;
    if (!url && list) url = str(list, flag) || str(list, Object.keys(list)[0]);
    return url ? { parse: 0, url, header: { 'User-Agent': BAIDU_PLAY_UA } } : { parse: 0, url: '', msg: '解析失败' };
}
function playHema(id) {
    if (/^https?:\/\/.*\.(mp4|m3u8)(\?.*)?$/i.test(id)) return { parse: 0, url: id };
    const [book, chapter] = id.split('+');
    if (chapter == null) return { parse: 0, url: '', msg: '解析失败' };
    const page = nextData(`${HEMA}/episode/${enc(book)}/${enc(chapter)}`);
    let url = mp4Of((((page.data.props || {}).pageProps || {}).chapterInfo || {}).chapterVideoVo);
    if (!url) { const m = page.html.match(/(https?:\/\/[^"']+\.mp4[^"']*)/i); if (m) url = m[1].replace(/\\\//g, '/'); }
    return url ? { parse: 0, url } : { parse: 0, url: '', msg: '解析失败' };
}

export default {
    home() {
        const filters = {
            七猫: [group('area', '分类', '全部', '0', '男频', '1', '新剧', '3', '现代言情', '21', '神豪', '37', '萌宝', '356', '穿越', '373', '战神', '527', '神医', '1269', '古装', '1272')],
            星芽: [group('area', '剧场', '剧场', '1', '热播短剧', '2', '会员专享', '8', '星选好剧', '7', '新剧', '3', '阳光剧场', '5', '排行榜', '9'),
                group('class2', '类型', '全部', '0', '都市', '4', '逆袭', '7', '古装', '5', '亲情', '41', '现代言情', '15', '重生', '6', '虐恋', '8', '玄幻', '35', '穿越', '17', '脑洞', '32', '甜宠', '33', '古代言情', '37', '战神', '24', '历史', '40', '赘婿', '26', '萌宝', '9', '神医', '25'),
                group('rank', '榜单', '实时热榜', '1', '热搜榜', '2', '新剧榜', '3', '剧单榜', '4', '口碑榜', '5')],
            西饭: [group('area', '分类', ...['都市', '甜宠', '逆袭', '战神', '古装', '穿越', '萌宝'].flatMap(v => [v, v]))],
            围观: [group('area', '分类', '全部', '', ...['都市', '逆袭', '家庭', '古装', '复仇', '甜宠', '悬疑', '爱情', '重生', '总裁', '穿越', '萌宝', '战神', '职场', '神豪', '神医', '赘婿'].flatMap(v => [v, v]))],
            河马: [group('area', '分类', '甜宠', '462', '古装仙侠', '1102', '现代言情', '1145', '青春', '1170', '豪门恩怨', '585', '逆袭', '417-464', '重生', '439-465', '系统', '1159', '总裁', '1147', '职场商战', '943')]
        };
        try {
            const tags = new Map();
            const add = list => { for (const t of list || []) if (t && str(t, 'tag_id')) tags.set(str(t, 'tag_id'), str(t, 'name')); };
            const data = haokanShelf();
            add(data.playlet_tags);
            for (const panel of data.playlet_shelf_filter_panel || []) if (panel) add(panel.tag_list);
            filters.好看 = [{ key: 'area', name: '分类', value: [{ n: '推荐', v: '' }, ...[...tags].map(([v, n]) => ({ n, v }))] }];
        } catch { filters.好看 = [group('area', '分类', '推荐', '')]; }
        return { class: SOURCES.map(([type_id, type_name]) => ({ type_id, type_name })), list: [], filters };
    },
    homeVod() { return this.category('七猫', '1', false, {}); },
    category(tid, pg, filter, extend = {}) {
        const page = Math.max(1, parseInt(pg, 10) || 1);
        try { return category[tid] ? category[tid](page, extend || {}) : result([], page, 1, 0, 0); } catch { return result([], page, 1, 0, 0); }
    },
    detail(ids) {
        const list = [], errors = [];
        for (const id of String(ids).split(',')) {
            const at = id.indexOf('@');
            if (at < 0 || !detail[id.slice(0, at)]) continue;
            try { list.push(detail[id.slice(0, at)](id, id.slice(at + 1))); } catch (e) { errors.push(`${id.slice(0, at)}: ${e && e.message || e}`); }
        }
        return list.length || !errors.length ? { list } : { list, msg: errors.join('; ') };
    },
    search(wd, quick, pg) {
        const page = Math.max(1, parseInt(pg, 10) || 1);
        const list = [], seen = new Set();
        if (!wd) return result(list, page, 1, 0, 0);
        for (const source of ['七猫', '星芽', '西饭', '围观', '河马', '好看']) {
            try { for (const v of search[source](page, String(wd))) if (v.vod_id && !seen.has(v.vod_id)) { seen.add(v.vod_id); list.push(v); } } catch {}
        }
        return result(list, page, 1, list.length, list.length);
    },
    play(flag, id) {
        id = String(id);
        try {
            if (String(flag).includes('河马')) return playHema(id);
            if (id.startsWith('围观@')) return { parse: 0, url: id.slice(3), header: WG_HEADERS };
            if (!id.startsWith('http') && id.includes('@')) return playHaokan(String(flag), id);
            return { parse: 0, url: id };
        } catch { return { parse: 0, url: '', msg: '解析失败' }; }
    }
};
