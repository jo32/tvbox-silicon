import Foundation
import Testing
@testable import TVCore

@Test func contributorsDecodeTheWorkersList() throws {
    // As Services/error-reports answers /v1/contributors; a person without an avatar has no key for it.
    let json = #"{"since":"2026-09-29T12:00:00.000Z","days":30,"contributors":[{"login":"bob","avatar":"https://avatars.githubusercontent.com/u/1?v=4","profile":"https://github.com/bob","commits":3},{"login":"amy","commits":1}]}"#
    let list = try JSONDecoder().decode(Contributors.self, from: Data(json.utf8))
    #expect(list.days == 30)
    #expect(list.contributors.map(\.login) == ["bob", "amy"])
    #expect(list.contributors[0].profile == URL(string: "https://github.com/bob"))
    #expect(list.contributors[1].avatar == nil && list.contributors[1].commits == 1)
}

@Test func avatarsAskForTheirSize() {
    let person = Contributor(login: "amy", avatar: URL(string: "https://avatars.githubusercontent.com/u/1?v=4&s=40"), commits: 1)
    #expect(person.avatar(points: 30)?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4&s=90")
}
