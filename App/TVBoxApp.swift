import SwiftUI
import TVCore

@main struct TVBoxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = Store()
    init() {
        #if os(macOS)
        // Use thin overlay scrollers app-wide. With "Show scroll bars: Always" or a mouse attached,
        // AppKit otherwise draws wide legacy scrollers that crowd poster grids and the episode rail.
        // The app's own defaults domain takes precedence over the global setting.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(store)
                .tint(Brand.accent)
                .task { Diagnostics.shared.record(.info, "app", "Application scene opened") }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        Task { _ = await Diagnostics.shared.snapshot() }
                    }
                }
                #if os(tvOS)
                .preferredColorScheme(.dark)
                #endif
                #if os(macOS)
                .frame(minWidth: 920, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 820)
        #endif
    }
}
