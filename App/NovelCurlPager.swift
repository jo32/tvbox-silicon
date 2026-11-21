#if os(iOS)
import SwiftUI
import UIKit

/// A turn asked for by a tap or the chapter's end, played with the curl.
struct NovelCurlRequest: Equatable {
    var id = 0
    var forward = true
}

/// The page layout turned with a curl, as in Books (仿真翻页, #1437/#1452): UIKit's own page curl over the same pages
/// the slide turn draws. A finger drags the corner; taps stay the reader's (sides turn, the middle shows the controls)
/// and come in as `request`, so UIKit's own tap-to-turn is off. Only the pages on screen and the one being turned to
/// are made, as the slide turn does.
struct NovelCurlPager: UIViewControllerRepresentable {
    let place: NovelPlace
    let key: NovelPageKey
    let request: NovelCurlRequest
    /// The place one screen on or back, nil at the book's ends or before the next chapter is fetched.
    let step: (NovelPlace, Bool) -> NovelPlace?
    let page: (NovelPlace) -> AnyView
    /// A turn finished on this place.
    let moved: (NovelPlace) -> Void
    /// A finger reached a chapter that isn't fetched yet.
    let blocked: (NovelPlace, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.isDoubleSided = false
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer { recognizer.isEnabled = false }
        controller.view.backgroundColor = .clear
        context.coordinator.parent = self
        context.coordinator.handled = request.id
        context.coordinator.key = key
        controller.setViewControllers([context.coordinator.host(place)], direction: .forward, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard !coordinator.animating else { return }
        if coordinator.key != key || coordinator.shown(controller) != place {
            // Another chapter opened, or the type changed: the page is set again where reading is.
            coordinator.key = key
            controller.setViewControllers([coordinator.host(place)], direction: .forward, animated: false)
        } else {
            // The page on screen keeps up with the reader (its controls hide the running head and the page count).
            for case let host as Host in controller.viewControllers ?? [] { host.rootView = page(host.place) }
        }
        if request.id != coordinator.handled {
            coordinator.handled = request.id
            guard let target = step(place, request.forward) else { return }
            coordinator.animating = true
            controller.setViewControllers([coordinator.host(target)], direction: request.forward ? .forward : .reverse, animated: true) { [weak coordinator] _ in
                coordinator?.animating = false
                coordinator?.parent?.moved(target)
            }
        }
    }

    /// One page, hosted for UIKit; it lays out edge to edge as the slide pages do.
    final class Host: UIHostingController<AnyView> {
        let place: NovelPlace
        init(place: NovelPlace, rootView: AnyView) {
            self.place = place
            super.init(rootView: rootView)
            safeAreaRegions = []
            view.backgroundColor = .clear
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    }

    @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: NovelCurlPager?
        var key: NovelPageKey?
        var handled = 0
        var animating = false

        func host(_ place: NovelPlace) -> Host { Host(place: place, rootView: parent?.page(place) ?? AnyView(EmptyView())) }
        func shown(_ controller: UIPageViewController) -> NovelPlace? { (controller.viewControllers?.first as? Host)?.place }

        private func neighbour(of controller: UIViewController, forward: Bool) -> UIViewController? {
            guard let parent, let place = (controller as? Host)?.place else { return nil }
            guard let target = parent.step(place, forward) else { parent.blocked(place, forward); return nil }
            return host(target)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            neighbour(of: viewController, forward: false)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            neighbour(of: viewController, forward: true)
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            animating = true
        }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            animating = false
            if completed, let place = shown(pageViewController) { parent?.moved(place) }
        }
    }
}
#endif
