import Foundation
import Testing
@testable import TVCore

@Test func prefixedTransportStreamIsNormalized() {
    let prefix = Data([137,80,78,71,13,10,26,10] + Array(repeating: 0, count: 53))
    var ts = Data(repeating: 0, count: 188 * 6)
    for i in 0..<6 { ts[i * 188] = 0x47 }
    #expect(MediaPayload.transportStream(prefix + ts) == ts)
    #expect(MediaPayload.transportStream(ts) == ts)
}
@Test func regularImagesAndUnrecognizedPayloadsArePreserved() {
    var png = Data([137,80,78,71,13,10,26,10] + Array(repeating: 0, count: 1200))
    png[61] = 0x47
    #expect(MediaPayload.transportStream(png) == png)
    #expect(MediaPayload.transportStream(Data()) == Data())
}
