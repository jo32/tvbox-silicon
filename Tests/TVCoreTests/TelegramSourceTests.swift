import Foundation
import Testing
@testable import TVCore

@Test func telegramChannelAddressesNameTheirChannel() {
    #expect(TelegramSource.channel(URL(string: "https://t.me/RMDJ33")!) == "RMDJ33")
    #expect(TelegramSource.channel(URL(string: "https://t.me/s/RMDJ33")!) == "RMDJ33")
    #expect(TelegramSource.channel(URL(string: "https://telegram.me/RMDJ33/1175")!) == "RMDJ33")
    #expect(TelegramSource.channel(URL(string: "https://t.me/RMDJ33/1175?comment=38825")!) == "RMDJ33")
    // Invite links and private channels have no public preview.
    #expect(TelegramSource.channel(URL(string: "https://t.me/+AbCdEfGh")!) == nil)
    #expect(TelegramSource.channel(URL(string: "https://t.me/joinchat/AAAAAE")!) == nil)
    #expect(TelegramSource.channel(URL(string: "https://t.me/c/1234567/89")!) == nil)
    #expect(TelegramSource.channel(URL(string: "https://example.com/RMDJ33")!) == nil)
}

@Test func telegramChannelImportsAsOneBuiltInSource() {
    let subscription = TelegramSource.subscription("RMDJ33", origin: URL(string: "https://t.me/RMDJ33")!)
    #expect(subscription.sites.count == 1)
    let site = subscription.sites[0]
    #expect(site.key == "builtin.telegram.rmdj33")
    #expect(site.api == "csp_YingxiaTelegram")
    #expect(site.isTelegram)
    #expect(site.isBuiltIn)
    #expect(TelegramSource.channel(of: site) == "RMDJ33")
}

// The channel's subscription carries no spider, and its `csp_` api reads as a JAR class, so the
// source lists, the home row and search left it out (#2012).
@Test func telegramChannelIsBrowsableWithoutASpider() {
    let origin = URL(string: "https://t.me/RMDJ33")!
    let site = TelegramSource.subscription("RMDJ33", origin: origin).sites[0]
    #expect(site.canBrowse(jarURL: nil))
    // Merged with another subscription that has a JAR: the channel's own subscription still has none.
    var merged = site
    merged.provenance = SourceProvenance(origin: origin, spider: nil)
    #expect(merged.canBrowse(jarURL: URL(string: "https://example.com/spider.jar")))
    #expect(SourceLists.browsable([merged], jarURL: nil, userHidden: { _ in false }).map(\.key) == [site.key])
}

@Test func telegramPreviewPostsCarryTitlesPostersAndEpisodeLinks() {
    let posts = TelegramSource.posts(in: telegramPreview, channel: "RMDJ33")
    #expect(posts.count == 2)
    let drama = posts[0]
    #expect(drama.id == 1175)
    #expect(drama.title == "测试短剧")
    #expect(drama.poster == "https://cdn.example.com/poster.jpg")
    #expect(drama.date == "2026-11-20")
    #expect(drama.video == nil)
    #expect(drama.links.map(\.name) == ["第1集-第10集", "第11集-第20集", "https://bit.ly/example"])
    #expect(drama.links[0].url == "https://t.me/RMDJ33/1175?comment=38825")
    let clip = posts[1]
    #expect(clip.id == 1176)
    #expect(clip.video == "https://cdn.example.com/movie.mp4")
}

@Test func telegramPostDetailsListCommentRangesAsEpisodes() throws {
    let drama = TelegramSource.posts(in: telegramPreview, channel: "RMDJ33")[0]
    let fields = try TelegramSource.details(drama, channel: "RMDJ33")
    #expect(fields["vod_play_from"]?.string == "Telegram")
    let episodes = fields["vod_play_url"]?.string ?? ""
    #expect(episodes.contains("第1集-第10集$https://t.me/RMDJ33/1175?comment=38825&embed=1"))
    #expect(episodes.contains("第11集-第20集$https://t.me/RMDJ33/1175?comment=38826&embed=1"))
    #expect(episodes.contains("https://bit.ly/example"))
}

@Test func telegramEmbedPagesGiveTheirDirectVideo() {
    let embed = #"<div class="tgme_widget_message" data-post="RMDJ33/1175"><video src="https://cdn.example.com/ep1.mp4" controls></video></div>"#
    #expect(TelegramSource.video(in: embed) == "https://cdn.example.com/ep1.mp4")
    #expect(TelegramSource.embedAddress("https://t.me/RMDJ33/1175?comment=38825") == "https://t.me/RMDJ33/1175?comment=38825&embed=1")
    #expect(TelegramSource.embedAddress("https://bit.ly/example") == "https://bit.ly/example")
}

@Test func telegramPreviewPageLoadsOlderPostsBeforeAnId() {
    #expect(TelegramSource.previewURL(channel: "RMDJ33", before: nil).absoluteString == "https://t.me/s/RMDJ33")
    #expect(TelegramSource.previewURL(channel: "RMDJ33", before: 1175).absoluteString == "https://t.me/s/RMDJ33?before=1175")
}

private let telegramPreview = """
<div class="tgme_widget_message_wrap js-widget_message_wrap"><div class="tgme_widget_message text_not_supported_wrap js-widget_message" data-post="RMDJ33/1175">
<div class="tgme_widget_message_user"><a href="https://t.me/RMDJ33"><i class="tgme_widget_message_user_photo"><img src="https://cdn.example.com/avatar.jpg"></i></a></div>
<div class="tgme_widget_message_bubble">
<a class="tgme_widget_message_photo_wrap" href="https://t.me/RMDJ33/1175" style="background-image:url('https://cdn.example.com/poster.jpg')"></a>
<div class="tgme_widget_message_text js-message_text" dir="auto">测试短剧<br>简介内容<br>剧集选择：<a href="https://t.me/RMDJ33/1175?comment=38825">第1集-第10集</a> <a href="https://t.me/RMDJ33/1175?comment=38826">第11集-第20集</a><br>主线路： <a href="https://bit.ly/example" target="_blank">https://bit.ly/example</a></div>
<div class="tgme_widget_message_footer"><a class="tgme_widget_message_date" href="https://t.me/RMDJ33/1175"><time datetime="2026-11-20T12:00:00+00:00" class="time">12:00</time></a></div>
</div></div></div>
<div class="tgme_widget_message_wrap js-widget_message_wrap"><div class="tgme_widget_message js-widget_message" data-post="RMDJ33/1176">
<div class="tgme_widget_message_video_player"><video src="https://cdn.example.com/movie.mp4" poster="https://cdn.example.com/p.jpg"></video></div>
<div class="tgme_widget_message_text js-message_text" dir="auto">直发视频</div>
<time datetime="2026-11-21T08:30:00+00:00" class="time">08:30</time>
</div></div>
"""
