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
            SettingsGroup(title: L10n.text("Built-in Runtime · Experimental"),
                          footer: L10n.text("The app includes a DEX interpreter without JIT and a test JAR. Mac also includes a JVM and Android native library compatibility layer for JAR plugins. The test below checks the basic DEX interpreter.")) {
                SettingsRow(symbol: "cpu.fill", tint: .indigo, title: L10n.text("Run Built-in Test JAR"), subtitle: probeSummary) {
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
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.text("Working…")).foregroundStyle(.secondary) }
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
            ? L10n.text("Inspection does not confirm execution. Mac uses an additional local compatibility layer on the Sources screen; other platforms do not support it yet.")
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
