import CryptoKit
import Foundation
import Testing
@testable import TVCore

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func signed(_ json: String, by key: Curve25519.Signing.PrivateKey) throws -> Account.Entitlement {
    let payload = Data(json.utf8)
    return Account.Entitlement(payload: base64URL(payload), signature: base64URL(try key.signature(for: payload)))
}

@Test func entitlementOfTheServerSaysWhenProEnds() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let entitlement = try signed(#"{"v":1,"user":"u_ABC","until":1900000000,"issued":1800000000}"#, by: key)
    #expect(ProEntitlement.until(entitlement, user: "u_ABC", key: publicKey) == Date(timeIntervalSince1970: 1_900_000_000))
    // Someone else's, or never Pro.
    #expect(ProEntitlement.until(entitlement, user: "u_OTHER", key: publicKey) == nil)
    let none = try signed(#"{"v":1,"user":"u_ABC","until":0,"issued":1800000000}"#, by: key)
    #expect(ProEntitlement.until(none, user: "u_ABC", key: publicKey) == nil)
}

@Test func entitlementNotSignedByTheServerIsIgnored() throws {
    let server = Curve25519.Signing.PrivateKey()
    let forger = Curve25519.Signing.PrivateKey()
    let publicKey = server.publicKey.rawRepresentation.base64EncodedString()
    let forged = try signed(#"{"v":1,"user":"u_ABC","until":1900000000,"issued":1800000000}"#, by: forger)
    #expect(ProEntitlement.until(forged, user: "u_ABC", key: publicKey) == nil)
    // A real signature over a changed payload.
    var edited = try signed(#"{"v":1,"user":"u_ABC","until":1900000000,"issued":1800000000}"#, by: server)
    edited.payload = base64URL(Data(#"{"v":1,"user":"u_ABC","until":4000000000,"issued":1800000000}"#.utf8))
    #expect(ProEntitlement.until(edited, user: "u_ABC", key: publicKey) == nil)
    // The app's own key is a valid Ed25519 key.
    #expect(try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: ProEntitlement.publicKey)!).rawRepresentation.count == 32)
}

@Test func accountDecodesWhatTheServerSends() throws {
    let json = #"""
    {"id":"u_4H90N92HX5RCQ8Z568P5","name":"Ann","identities":[{"provider":"apple","label":"a@privaterelay.appleid.com","created":1795239984},
    {"provider":"telegram","label":"@ann","created":1795239990}],"pro":{"active":true,"until":1797831984,"lifetime":false},
    "entitlement":{"payload":"eyJ2IjoxfQ","signature":"c2ln"},"feedback":{"sent":3,"adopted":2,"declined":1,"points":23,"rewardDays":0,
    "issues":[{"number":104,"title":"Picture in picture","status":"adopted","sent":1795240000}]},"telegramBot":"YingxiaBot"}
    """#
    let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    #expect(account.displayName == "Ann")
    #expect(account.has("telegram") && account.has("apple"))
    #expect(account.feedback.points == 23 && account.feedback.issues.first?.status == "adopted")
    let signedOut = try JSONDecoder().decode(Account.self, from: Data(json.replacingOccurrences(of: #""entitlement":{"payload":"eyJ2IjoxfQ","signature":"c2ln"}"#, with: #""entitlement":null"#).utf8))
    #expect(signedOut.entitlement == nil)
}

@Test func accountDecodesPointsAndPullRequests() throws {
    let json = #"""
    {"id":"u_4H90N92HX5RCQ8Z568P5","name":"Ann","identities":[],"pro":{"active":false,"until":null,"lifetime":false},"entitlement":null,
    "feedback":{"sent":1,"adopted":1,"declined":0,"points":1601,"rewardDays":0,"issues":[]},
    "points":{"total":1601,"days":0,"sent":1,"adopted":1,"pullRequests":3,"adjusted":0,"rules":{"daily":1,"sent":1,"sentPerDay":3,"adopted":100,"pullRequest":500}},
    "pullRequests":[{"number":1290,"title":"Sleep timer","merged":1795239984}]}
    """#
    let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    #expect(account.points?.total == 1601 && account.points?.rules.pullRequest == 500 && account.pullRequests?.first?.number == 1290)
    // A server from before points: the account still decodes.
    let older = try JSONDecoder().decode(Account.self, from: Data(json.replacingOccurrences(of: #""points":{"total""#, with: #""unused":{"total""#).utf8))
    #expect(older.points == nil)
}

@Test func fixedBugsAndAdoptedIdeasEarnTheirOwnPoints() throws {
    let points = try JSONDecoder().decode(Account.Points.self, from: Data(
        #"{"total":201,"days":0,"sent":1,"fixed":2,"adopted":1,"pullRequests":0,"adjusted":0,"rules":{"daily":1,"sent":1,"sentPerDay":3,"fixed":50,"adopted":100,"pullRequest":500}}"#.utf8))
    #expect(points.fixed == 2 && points.rules.fixed == 50 && points.feedbackEarned == 200)
    // A server from before the split counted fixed bugs as adopted, at the one rate it sent.
    let older = try JSONDecoder().decode(Account.Points.self, from: Data(
        #"{"total":31,"days":0,"sent":1,"adopted":1,"pullRequests":0,"adjusted":0,"rules":{"daily":1,"sent":1,"sentPerDay":3,"adopted":30,"pullRequest":500}}"#.utf8))
    #expect(older.fixed == 0 && older.rules.fixed == 30 && older.feedbackEarned == 30)
    #expect(Account.Points.Rules.standard.fixed == 50 && Account.Points.Rules.standard.adopted == 100)
}

@Test func everyRedeemRefusalHasItsOwnMessage() {
    let reasons = ["not_found", "revoked", "expired", "used_up", "already_redeemed"]
    let messages = Set(reasons.map { AccountService.Failure.code($0).errorDescription ?? "" })
    #expect(messages.count == reasons.count && !messages.contains(""))
}
