import Foundation
import Testing
@testable import TVCore

private func transportStream(packets: Int = 6) -> Data {
    var ts = Data(repeating: 0, count: 188 * packets)
    for i in 0..<packets { ts[i * 188] = 0x47 }
    return ts
}

@Test func prefixedTransportStreamIsNormalized() {
    let prefix = Data([137,80,78,71,13,10,26,10] + Array(repeating: 0, count: 53))
    let ts = transportStream()
    #expect(MediaPayload.transportStream(prefix + ts) == ts)
    #expect(MediaPayload.transportStream(ts) == ts)
}
@Test func otherDisguisingPicturesAreDroppedToo() {
    let ts = transportStream(packets: 8)
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10] + Array("JFIF".utf8) + Array(repeating: 7, count: 600) + [0xFF, 0xD9])
    // A GIF starts with "G", the packet sync byte, which kept AVPlayer from ever starting such a segment.
    let gif = Data(Array("GIF89a".utf8) + Array(repeating: 1, count: 37))
    let bmp = Data(Array("BM".utf8) + Array(repeating: 2, count: 56))
    let webp = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + Array(repeating: 3, count: 30))
    // A large picture as well: up to 64 KB.
    let large = Data([137,80,78,71,13,10,26,10] + Array(repeating: 9, count: 40_000))
    for prefix in [jpeg, gif, bmp, webp, large] { #expect(MediaPayload.transportStream(prefix + ts) == ts) }
}
@Test func regularImagesAndUnrecognizedPayloadsArePreserved() {
    var png = Data([137,80,78,71,13,10,26,10] + Array(repeating: 0, count: 1200))
    png[61] = 0x47
    #expect(MediaPayload.transportStream(png) == png)
    #expect(MediaPayload.transportStream(Data()) == Data())
    // Something else before the packets (an ID3 tag, an HTML page) is not a picture: left as it was.
    let tagged = Data(Array("ID3".utf8) + Array(repeating: 0, count: 40)) + transportStream()
    #expect(MediaPayload.transportStream(tagged) == tagged)
}
