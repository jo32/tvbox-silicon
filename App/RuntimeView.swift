import SwiftUI
import TVCore

struct RuntimeView: View {
    @Environment(Store.self) private var store
    @State private var busy = false
    @State private var report: JarReport?
    @State private var probe: JarReport?
    @State private var error: String?
    private let runtime = JarRuntime()
    var body: some View {
        SettingsPage(title: L10n.text("JAR Runtime")) {
            #if os(iOS) || os(tvOS)
            SettingsGroup(title: L10n.text("On-device Plugin Runtime"),
                          footer: L10n.text("Plugin sources run on this device without a server. First use prepares and caches the required classes. Some Android features are not supported.")) {
                SettingsRow(symbol: "cpu.fill", tint: Brand.terracotta, title: L10n.text("Java Plugin Support"),
                            subtitle: EmbeddedJarHost.available ? L10n.text("Installed · Experimental") : L10n.text("Not installed in this build"))
            }
            #endif
            SettingsGroup(title: L10n.text("Built-in Runtime · Experimental"),
                          footer: L10n.text("This small test checks basic DEX instructions. Open a source to test the full plugin runtime.")) {
                SettingsRow(symbol: "cpu.fill", tint: Brand.terracotta, title: L10n.text("Run Built-in Test JAR"), subtitle: probeSummary) {
                    Button(L10n.text("Run Test")) { Task { await runProbe() } }.settingsButton().disabled(busy)
                }
            }
            SettingsGroup(title: L10n.text("Current Subscription Plugin"), footer: reportFootnote) {
                if let config = store.subscription, let url = config.spiderURL {
                    SettingsRow(symbol: "shippingbox.fill", tint: .orange, title: url.lastPathComponent, subtitle: reportSummary) {
                        Button(L10n.text("Check")) { Task { await inspect(config) } }.settingsButton().disabled(busy)
                    }
                    if let report, report.status != 0 || report.needsAndroidNativeRuntime {
                        Label(report.status != 0 ? report.message : L10n.text("This plugin requires Android native libraries"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Brand.amber)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                } else {
                    SettingsRow(symbol: "shippingbox.fill", tint: .gray, title: L10n.text("Import a subscription with a spider field first."))
                }
            }
            SettingsGroup {
                SettingsLinkRow(symbol: "doc.text.magnifyingglass", tint: .gray, title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
            }
            if busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.text("Working…")).foregroundStyle(.secondary); ElapsedTime() }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.amber) }
        }
    }
    private var probeSummary: String? {
        guard let probe else { return nil }
        if probe.status == 0 && probe.value == 42 && probe.instructions > 0 {
            return L10n.text("Bytecode executed: returned 42 after %llu instructions", probe.instructions)
        }
        return L10n.text("Test failed: %@", probe.message)
    }
    private var reportSummary: String? {
        report.map { L10n.text("DEX files: %lld · Classes: %lld · Android libraries: %lld", $0.dexFiles, $0.classes, $0.nativeLibraries) }
    }
    private var reportFootnote: String? {
        guard let report, report.status == 0 else { return nil }
        return report.needsAndroidNativeRuntime
            ? L10n.text("Inspection does not confirm execution. Open the source to test its Android library compatibility.")
            : L10n.text("No bundled .so libraries found. CatVod APIs, Android APIs, and dynamic loading still need verification before playback can be confirmed.")
    }
    private func runProbe() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let url = Bundle.main.url(forResource: "runtime-probe", withExtension: "jar") else { throw TVError.unsupported(L10n.text("The test JAR could not be found.")) }
            probe = await runtime.runStaticInt(try Data(contentsOf: url), className: "Ltvbox/RuntimeProbe;", method: "run")
        } catch { self.error = error.localizedDescription }
    }
    private func inspect(_ config: Subscription) async {
        busy = true; error = nil
        defer { busy = false }
        do { report = try await runtime.inspect(subscription: config) }
        catch { self.error = error.localizedDescription }
    }
}
