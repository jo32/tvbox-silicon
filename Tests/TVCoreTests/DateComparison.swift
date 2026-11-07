import Foundation

// Xcode 27.2's SDK marks Foundation's `Date.<=` and `Date.>=` as
// `@backDeployed(before: iOS 27.2, macOS 27.2, tvOS 27.2, …)`. Every `a <= b`
// on dates then calls the OS copy whenever the system reports 27.2 or later.
// Early 27.2 betas (iOS 24B5084k, 24B5089g) report 27.2 but don't have the
// symbol yet, so the weak import is NULL and the app jumps to 0x0 at launch
// (TestFlight 51/52: MediaCache.prune, ErrorReports.due).
//
// An operator declared in the module being compiled shadows Foundation's, so
// no call site links the back-deployed symbol. Keep these internal and keep a
// copy in each Swift module that compares dates: TVCore, App and
// TVCoreTests (a public one would be ambiguous with Foundation's).
// Scripts/check-weak-imports.sh fails a build that imports them again.
extension Date {
    @_transparent static func <= (lhs: Date, rhs: Date) -> Bool { !(rhs < lhs) }
    @_transparent static func >= (lhs: Date, rhs: Date) -> Bool { !(lhs < rhs) }
}
