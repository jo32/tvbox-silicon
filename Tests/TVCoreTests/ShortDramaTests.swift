import Foundation
import Testing
@testable import TVCore

struct ShortDramaTests {
    @Test func xifanAndHemaListOnlyTheirFreeEpisodes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = #"""
        import xifan, { list as xifanList, detail as xifanDetail, genres as xifanGenres } from 'assets://sites/Xifan.js';
        import hema, { browse, detail as hemaDetail, genres as hemaGenres } from 'assets://sites/Hema.js';
        export default { async home() {
            const checks = {}, asked = [];
            let rejected;
            const labels = { episode: 'Episode %@', episodes: '%@ Episodes', free: '%@ of %@ free', all: 'All', locked: 'Locked' };
            xifan.init({ ...labels, name: 'Xifan' });
            hema.init({ ...labels, name: 'Hema' });

            const genreAnswer = { elements: [{ contents: [{ categoryItemVo: { subCategories: [
                { categoryId: 68, oppoCategory: '都市', version: 2 }, { categoryId: 68, oppoCategory: '都市', version: 2 }, { categoryId: 0, oppoCategory: 'x' }] } }] }] };
            checks.xifanGenres = JSON.stringify(xifanGenres(genreAnswer)) === JSON.stringify([{ type_id: '68:2:都市', type_name: '都市' }]);
            const page = xifanList({ hasMore: true, elements: [{ contents: [
                { duanjuVo: { source: 'jiuzhou', duanjuId: '1335', title: '九州<tag>战神</tag>', coverImageUrl: 'https://a.example/b.jpg?x-amz-process=image/format,webp/quality,Q_20', total: 92 } },
                { duanjuVo: { source: 'bad source', duanjuId: '1', title: 'x' } }] }] }, 2);
            checks.xifanList = page.list.length === 1 && page.list[0].vod_id === 'jiuzhou:1335' && page.list[0].vod_name === '九州战神'
                && page.list[0].vod_remarks === '92 Episodes' && page.pagecount === 3
                && page.list[0].vod_pic === 'https://a.example/b.jpg?x-amz-process=image/format,webp/quality,Q_80';
            const series = { source: 'jiuzhou', duanjuId: '1335', title: 'T', desc: 'D', actorList: [{ name: 'A' }], categories: ['都市'], episodeList: [
                { episodeId: '3', index: 3, unlock: false, playUrl: 'https://p.example/3' },
                { episodeId: '1', index: 1, unlock: true, playUrl: 'https://p.example/1' },
                { episodeId: '2', index: 2, unlock: true, playUrl: 'http://p.example/2' }] };
            const video = xifanDetail(series, 'jiuzhou:1335').list[0];
            checks.xifanDetail = video.vod_play_url === 'Episode 1$jiuzhou:1335/1' && video.vod_remarks === '1 of 3 free'
                && video.vod_actor === 'A' && video.vod_content === 'D' && video.vod_play_from === 'Xifan';
            globalThis.req = url => { asked.push(url); return { code: 200, content: JSON.stringify({ ret: 0, result: series }) }; };
            checks.xifanPlay = xifan.play('Xifan', 'jiuzhou:1335/1').url === 'https://p.example/1'
                && asked[0].startsWith('https://xifan-api-cn.youlishipin.com/xifan/drama/getDuanjuInfo?source=jiuzhou&duanjuId=1335&');
            rejected = false; try { xifan.play('Xifan', 'jiuzhou:1335/3'); } catch (error) { rejected = error.message === 'Locked'; }
            checks.xifanLocked = rejected;
            globalThis.req = () => ({ code: 200, content: JSON.stringify({ ret: 0, result: { ...series, duanjuId: '9' } }) });
            rejected = false; try { xifan.detail('jiuzhou:1335'); } catch { rejected = true; }
            checks.xifanOtherSeries = rejected;

            const next = props => `<script id="__NEXT_DATA__" type="application/json">${JSON.stringify({ props: { pageProps: props } })}</script>`;
            checks.hemaGenres = JSON.stringify(hemaGenres({ typeThreeList: [{ name: '萌宝', typeThreeIds: [589, 1175] }, { name: 'x', typeThreeIds: ['a'] }] }).map(g => g.type_id))
                === JSON.stringify(['0', '589-1175']);
            const book = { bookId: '41000452675', bookName: '假妻', coverWap: 'https://s.example/41.jpg?t=1&imageView2/0/w/200/h/267', totalChapterNum: '60',
                introduction: 'I', actor: 'A', actress: 'B', bookTypeThree: [{ name: '漫剧' }] };
            const browsed = browse(next({ bookList: [book, book], page: 2, typeThreeId: '589-1175' }) + '<a class="x" href="/browse/589-1175/3">3</a>', '589-1175', 2);
            checks.hemaBrowse = browsed.list.length === 1 && browsed.list[0].vod_pic === 'https://s.example/41.jpg?t=1' && browsed.pagecount === 3;
            rejected = false; try { browse(next({ bookList: [book], page: 1, typeThreeId: '0' }), '589-1175', 1); } catch { rejected = true; }
            checks.hemaOtherGenre = rejected;
            const chapters = [{ chapterId: '2', chapterIndex: 2, isCharge: '1', chapterVideoVo: { mp4: 'https://v.example/2.mp4' } },
                { chapterId: '1', chapterIndex: 1, isCharge: '0', chapterVideoVo: { mp4: 'https://v.example/1.mp4' } }];
            const drama = hemaDetail({ bookInfoVo: book, chapterList: chapters }, '41000452675').list[0];
            checks.hemaDetail = drama.vod_play_url === 'Episode 1$41000452675/1' && drama.vod_remarks === '1 of 2 free' && drama.vod_actor === 'A,B';
            globalThis.req = () => ({ code: 200, content: next({ bookInfoVo: book, chapterList: chapters }) });
            checks.hemaPlay = hema.play('Hema', '41000452675/1').url === 'https://v.example/1.mp4';
            rejected = false; try { hema.play('Hema', '41000452675/2'); } catch (error) { rejected = error.message === 'Locked'; }
            checks.hemaLocked = rejected;
            let posted;
            globalThis.req = (url, options) => { posted = { url, options }; return { code: 200, content: JSON.stringify({ retCode: 0, data: { isMore: 1, bookList: [book] } }) }; };
            const found = hema.search(' 总裁 ', false, '1');
            checks.hemaSearch = found.list.length === 1 && found.pagecount === 2 && posted.url === 'https://www.kuaikaw.cn/seo/video/6007'
                && posted.options.method === 'POST' && JSON.parse(posted.options.body).keyword === '总裁';
            globalThis.req = () => ({ code: 503, content: '' });
            rejected = false; try { hema.search('x', false, '1'); } catch (error) { rejected = error.message !== 'Locked'; }
            checks.hemaUnavailable = rejected;
            return { checks };
        } };
        """#
        let session = try await ScriptSession.start(api: "https://fixture.example/dramas.js", key: "drama-fixture", ext: "", profile: folder, label: "drama-fixture", source: source)
        defer { session.close() }
        let envelope = try await session.call([:])
        let json = try #require(envelope["result"]?.string, "\(envelope)")
        let checks = try #require(JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))["checks"]?.object)
        #expect(checks.count == 14)
        for (name, result) in checks { #expect(result == .bool(true), "\(name)") }
    }
}
