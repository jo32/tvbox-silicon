import Foundation
import Testing
@testable import TVCore

@Test func telegramChannelAddressMayNameItsReadingEntry() {
    #expect(TelegramSource.channel(URL(string: "https://proxy.example/https://t.me/RMDJ33")!) == "RMDJ33")
    #expect(TelegramSource.channel(URL(string: "https://proxy.example/https:/t.me/RMDJ33")!) == "RMDJ33")
    #expect(TelegramSource.channel(URL(string: "https://proxy.example/tg/https://t.me/RMDJ33/1175?comment=38825")!) == "RMDJ33")
    // An invite or private channel names none, however it is wrapped.
    #expect(TelegramSource.channel(URL(string: "https://proxy.example/https://t.me/+AbCdEfGh")!) == nil)
    #expect(TelegramSource.channel(URL(string: "https://proxy.example/https://t.me/joinchat/AAAAAE")!) == nil)
}

@Test func telegramChannelReadsThroughTheEntryItsAddressNamed() {
    let endpoint = TelegramEndpoint.split(URL(string: "https://proxy.example/https://t.me/RMDJ33")!)!.endpoint
    #expect(endpoint.base.absoluteString == "https://proxy.example")
    #expect(TelegramSource.previewURL(channel: "RMDJ33", before: nil, endpoint: endpoint).absoluteString
        == "https://proxy.example/https://t.me/s/RMDJ33")
    #expect(TelegramSource.previewURL(channel: "RMDJ33", before: 1175, endpoint: endpoint).absoluteString
        == "https://proxy.example/https://t.me/s/RMDJ33?before=1175")
}

@Test func telegramChannelSubscriptionKeepsItsEntry() {
    let origin = URL(string: "https://proxy.example/https://t.me/RMDJ33")!
    let site = TelegramSource.subscription("RMDJ33", origin: origin).sites[0]
    #expect(site.key == "builtin.telegram.rmdj33")
    #expect(site.raw["ext"]?.object?["endpoint"]?.string == "https://proxy.example")
    #expect(TelegramEndpoint.endpoint(of: site).base.absoluteString == "https://proxy.example")
}

@Test func telegramChannelSubscriptionWithoutAnEntryReadsTelegram() {
    let site = TelegramSource.subscription("RMDJ33", origin: URL(string: "https://t.me/RMDJ33")!).sites[0]
    #expect(site.raw["ext"]?.object?["endpoint"] == nil)
    #expect(TelegramEndpoint.endpoint(of: site) == .direct)
    #expect(TelegramSource.previewURL(channel: "RMDJ33", before: nil).absoluteString == "https://t.me/s/RMDJ33")
}

@Test func telegramEpisodeAddressReadsThroughTheEntry() {
    let endpoint = TelegramEndpoint.split(URL(string: "https://proxy.example/https://t.me/RMDJ33")!)!.endpoint
    #expect(TelegramSource.embedAddress("https://t.me/RMDJ33/1175?comment=38825", endpoint: endpoint)
        == "https://proxy.example/https://t.me/RMDJ33/1175?comment=38825&embed=1")
    // A line that isn't Telegram's stays as the post wrote it.
    #expect(TelegramSource.embedAddress("https://example.com/a.mp4", endpoint: endpoint) == "https://example.com/a.mp4")
}
