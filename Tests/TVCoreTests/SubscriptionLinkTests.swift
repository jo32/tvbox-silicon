import Foundation
import Testing
@testable import TVCore

@Test func importLinkReadsTheAddressAndName() throws {
    let url = try #require(URL(string: "yingxia://import?url=https%3A%2F%2Fexample.com%2Ftv.json&name=%E9%A5%AD%E5%A4%AA%E7%A1%AC"))
    let link = try #require(SubscriptionImportLink(url))
    #expect(link.address.absoluteString == "https://example.com/tv.json")
    #expect(link.name == "饭太硬")
    #expect(link.id == link.address.absoluteString)
}

@Test func importLinkKeepsAQueryTheAddressCarries() throws {
    let address = "https://example.com/tv.json?token=abc&v=2"
    let encoded = try #require(address.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
    let link = try #require(SubscriptionImportLink(try #require(URL(string: "yingxia://import?url=\(encoded)"))))
    #expect(link.address.absoluteString == address)
    #expect(link.name == nil)
}

@Test func importLinkRefusesAnythingTheAppWouldNotFetch() throws {
    for text in ["yingxia://import",
                 "yingxia://import?url=",
                 "yingxia://import?url=file%3A%2F%2F%2Fetc%2Fhosts",
                 "yingxia://import?url=javascript%3Aalert(1)",
                 "yingxia://import?url=not%20an%20address",
                 "https://example.com/import?url=https%3A%2F%2Fexample.com%2Ftv.json",
                 "yingxia://douyin-login?host=1.2.3.4&port=9&key=abc"] {
        let url = try #require(URL(string: text), "\(text)")
        #expect(SubscriptionImportLink(url) == nil, "\(text)")
    }
}

@Test func importLinkRoundTripKeepsTheAddressAndTrimsTheName() throws {
    let address = try #require(URL(string: "https://example.com/tv.json?token=abc"))
    let link = SubscriptionImportLink(address: address, name: "  Living Room  ")
    #expect(link.name == "Living Room")
    let again = try #require(SubscriptionImportLink(link.url))
    #expect(again.address == address)
    #expect(again.name == "Living Room")
    let unnamed = try #require(SubscriptionImportLink(SubscriptionImportLink(address: address).url))
    #expect(unnamed.name == nil)
    #expect(SubscriptionImportLink(address: address, name: "   ").name == nil)
}
