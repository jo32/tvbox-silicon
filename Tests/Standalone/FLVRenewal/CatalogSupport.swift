import Foundation
public struct Episode: Sendable, Equatable { let address: String; let flag: String }
public struct ExternalSubtitle: Sendable {}
public struct PlaybackSkip: Sendable {}
public enum JSONValue { case null; var string: String? { nil }; var int: Int? { nil }; var object: [String: JSONValue]? { nil }; var array: [JSONValue]? { nil } }
struct Channel: Sendable { var url: URL; var headers: [String: String]; var flvSource: FLVLive.Source? }
actor CatalogFixture {
    var requests: [Episode] = []
    var plans: [PlaybackPlan]
    init(_ plans: [PlaybackPlan]) { self.plans = plans }
    func prepare(_ episode: Episode) -> PlaybackPlan { requests.append(episode); return plans.removeFirst() }
}
