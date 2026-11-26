import Foundation
public struct Episode: Sendable, Equatable { let address: String; let flag: String }
public struct ExternalSubtitle: Sendable {}
public struct PlaybackSkip: Sendable {}
public enum JSONValue { case null; var string: String? { nil }; var int: Int? { nil }; var object: [String: JSONValue]? { nil }; var array: [JSONValue]? { nil } }
struct Channel: Sendable { var url: URL; var headers: [String: String]; var flvSource: FLVLive.Source? }
struct CatalogSite: Sendable { var type = 4 }
actor CatalogFixture {
    var requests: [Episode] = []
    var freshRequests: [Bool] = []
    var plans: [PlaybackPlan]
    init(_ plans: [PlaybackPlan]) { self.plans = plans }
    func prepare(_ episode: Episode, fresh: Bool) -> PlaybackPlan {
        requests.append(episode); freshRequests.append(fresh)
        return plans.removeFirst()
    }
}
