import Combine
import SwiftUI
import TVCore

/// 相容層自己的 placement 列舉，避免 macOS 13 上參照 ContentMarginPlacement。
enum CompatMarginPlacement {
    case scrollContent
    case compatAutomatic
}

/// macOS 13 沒有 ScrollPosition；保留相同呼叫形式，舊系統上不做偏移捲動。
final class CompatScrollPosition {
    func scrollTo(id: String?, anchor: UnitPoint? = nil) {}
    func scrollTo(x: CGFloat) {}
}

/// macOS 13 沒有帶 completion 的 withAnimation，改用延遲執行近似。
func compatWithAnimation(_ animation: Animation, _ body: () -> Void, completion: @escaping () -> Void) {
    #if os(macOS)
    if #available(macOS 14, *) {
        withAnimation(animation, body, completion: completion)
    } else {
        withAnimation(animation, body)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: completion)
    }
    #else
    withAnimation(animation, body, completion: completion)
    #endif
}

/// 讓 `@StateObject` 能持有可為 nil 的模型：SwiftUI 的 StateObject 不接受 Optional，
/// 這層同時把模型自己的 objectWillChange 轉送出去，維持視圖更新。
@MainActor final class ObservableHolder<T: ObservableObject>: ObservableObject {
    @Published var value: T? {
        didSet {
            cancellation = nil
            if let value {
                cancellation = value.objectWillChange
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.objectWillChange.send() }
            }
        }
    }
    private var cancellation: AnyCancellable?
    init(_ value: T? = nil) { self.value = value }
}

/// macOS 13 (Ventura) 相容層：把新版 SwiftUI API 包起來，舊系統降級成對應的舊 API 或無操作。
/// App 程式碼呼叫 `compat*` 版本，讓同一份原始碼同時支援 Ventura 與新版 macOS。
extension View {
    @ViewBuilder
    func compatOnChange<Value: Equatable>(of value: Value, initial: Bool = false, _ action: @escaping (Value, Value) -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) {
            onChange(of: value, initial: initial, action)
        } else {
            onChange(of: value) { action(value, $0) }
                .onAppear { if initial { action(value, value) } }
        }
        #else
        onChange(of: value, initial: initial, action)
        #endif
    }

    @ViewBuilder
    func compatOnChange<Value: Equatable>(of value: Value, _ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { onChange(of: value) { _, _ in action() } }
        else { onChange(of: value) { _ in action() } }
        #else
        onChange(of: value) { _, _ in action() }
        #endif
    }

    @ViewBuilder
    func compatOnChange<Value: Equatable>(of value: Value, _ action: @escaping (Value) -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { onChange(of: value) { _, new in action(new) } }
        else { onChange(of: value) { new in action(new) } }
        #else
        onChange(of: value) { _, new in action(new) }
        #endif
    }

    @ViewBuilder
    func compatSearchable(text: Binding<String>, isPresented: Binding<Bool>) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.searchable(text: text, isPresented: isPresented) }
        else { self.searchable(text: text) }
        #else
        self.searchable(text: text, isPresented: isPresented)
        #endif
    }

    /// macOS 13 沒有 ContentUnavailableView，改用同樣語意的簡易空狀態。
    @ViewBuilder
    func compatSearchUnavailable(text: String) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { ContentUnavailableView.search(text: text) }
        else {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                Text(L10n.text("No Results")).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        #else
        ContentUnavailableView.search(text: text)
        #endif
    }

    @ViewBuilder
    func compatScrollClipDisabled(_ disabled: Bool = true) -> some View {
        #if os(macOS)
        if #available(macOS 14, *), disabled { self.scrollClipDisabled() } else { self }
        #else
        self.scrollClipDisabled(disabled)
        #endif
    }

    @ViewBuilder
    func compatScrollTargetLayout(_ enabled: Bool = true) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.scrollTargetLayout(isEnabled: enabled) } else { self }
        #else
        self.scrollTargetLayout(isEnabled: enabled)
        #endif
    }

    @ViewBuilder
    func compatScrollPosition<ID: Hashable>(id: Binding<ID?>, anchor: UnitPoint? = nil) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.scrollPosition(id: id, anchor: anchor) } else { self }
        #else
        self.scrollPosition(id: id, anchor: anchor)
        #endif
    }

    @ViewBuilder
    func compatContentMargins(_ edges: Edge.Set = .all, _ length: CGFloat, for placement: CompatMarginPlacement = .scrollContent) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) {
            self.contentMargins(edges, length, for: placement == .compatAutomatic ? .automatic : .scrollContent)
        } else {
            self.padding(edges, length)
        }
        #else
        self.contentMargins(edges, length, for: placement == .compatAutomatic ? .automatic : .scrollContent)
        #endif
    }

    @ViewBuilder
    func compatOnKeyPress(_ key: KeyEquivalent, _ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.onKeyPress(key) { action(); return .handled } } else { self }
        #else
        self.onKeyPress(key) { action(); return .handled }
        #endif
    }

    @ViewBuilder
    func compatOnKeyPress(keys: [KeyEquivalent], _ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.onKeyPress(keys: Set(keys)) { _ in action(); return .handled } } else { self }
        #else
        self.onKeyPress(keys: Set(keys)) { _ in action(); return .handled }
        #endif
    }

    @ViewBuilder
    func compatFocusEffectDisabled() -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.focusEffectDisabled() } else { self }
        #else
        self.focusEffectDisabled()
        #endif
    }

    @ViewBuilder
    func compatToolbarRemovingTitle() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) { self.toolbar(removing: .title) } else { self }
        #else
        self
        #endif
    }

    @ViewBuilder
    func compatButtonBorderShape(_ shape: ButtonBorderShape) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.buttonBorderShape(shape) } else { self }
        #else
        self.buttonBorderShape(shape)
        #endif
    }

    @ViewBuilder
    func compatNavigationDestination<Item: Hashable, Destination: View>(item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) { self.navigationDestination(item: item, destination: destination) } else { self }
        #else
        self.navigationDestination(item: item, destination: destination)
        #endif
    }

    /// macOS 13 的 AppKit 手勢：捨棄新版 WindowDragGesture，保留原視圖。
    @ViewBuilder
    func compatWindowDrag() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) { self.gesture(WindowDragGesture()) } else { self }
        #else
        self
        #endif
    }
}
