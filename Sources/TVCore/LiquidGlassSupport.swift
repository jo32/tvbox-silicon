import Foundation

/// Whether a device draws Liquid Glass. tvOS 26 still runs on the Apple TV HD (AppleTV5,3) and the first
/// Apple TV 4K (AppleTV6,2), but Apple gives Liquid Glass only to the Apple TV 4K (2nd generation) and later.
public enum LiquidGlassSupport {
    public static let current = drawsGlass(model: ErrorReports.model)

    static func drawsGlass(model: String) -> Bool {
        guard model.hasPrefix("AppleTV"), let major = Int(model.dropFirst(7).prefix(while: \.isNumber)) else { return true }
        return major >= 11
    }
}
