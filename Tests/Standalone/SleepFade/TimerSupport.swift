import Foundation
@MainActor enum Diagnostics {
 static let shared = Logger()
 enum Level { case info }
 struct Logger { func record(_ level: Level, _ category: String, _ message: String) {} }
}
enum L10n { static func text(_ value: String, _ args: CVarArg...) -> String { value } }
enum SleepTimerItem { case song; var title: String { "Song" } }
