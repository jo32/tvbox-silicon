//
//  PlayerSurface.swift
//  TVBox
//
//  How the episode sheet and the end-of-series screen present themselves in each
//  of the three player shapes.
//
//  The three shapes, all driven by `MobilePlayerLayout`:
//
//    .screen         the player as a screen of its own (full-screen player)
//    .inline         the top of an iPhone watch page, under the status bar
//    .pageFullScreen a watch page's player filling the screen
//
//  Before this file the sheet and the end screen were attached once, in
//  PlayerView, with no regard for which shape was on screen. Two things went
//  wrong on a Duo:
//
//  * `inline` is a small picture at the top of a scrolling page. A sheet over it
//    slides up from the bottom of the *page*, so the episode grid opened mostly
//    off-screen, above the picture the viewer was looking at.
//  * `pageFullScreen` and `.screen` cover the whole display, and the end screen's
//    countdown kept running while the picture was hidden behind it — the next
//    season started before the viewer had seen the card.
//
//  So the surface decides, per shape: whether the sheet is a sheet or a panel
//  inside the picture, and where the end screen sits. It also owns the one rule
//  the Duo's inner display breaks if taken literally: orientation. The inner
//  display (regular both ways) ignores orientation locks, so the sheet must not
//  try to force one.
//

import SwiftUI
import TVCore

// MARK: - Surface

/// Decides how the player's auxiliary screens are presented for one layout.
struct PlayerSurface {
    let layout: MobilePlayerLayout

    /// The sheet is a real sheet only when the player already fills the screen.
    /// At the top of a watch page it becomes a panel drawn inside the picture
    /// instead, so the episode grid never opens above the thing the viewer is
    /// watching.
    var episodesPresentedAsSheet: Bool {
        switch layout {
        case .screen, .pageFullScreen: return true
        case .inline: return false
        }
    }

    /// The picture is small and the page scrolls under it: the panel is capped so
    /// it never grows past the picture and forces the page to scroll to reach the
    /// transport bar.
    var episodePanelMaxHeight: CGFloat? {
        layout == .inline ? 260 : nil
    }

    /// The end screen covers the picture in every shape; only the corner radius
    /// and inset differ, because `inline` has square edges against the page.
    var endScreenCornerRadius: CGFloat {
        layout == .inline ? 0 : 18
    }

    var endScreenInset: CGFloat {
        layout == .inline ? 0 : 14
    }

    /// The end screen's countdown may run only when the viewer can actually see
    /// it. `inline` keeps the page behind it, so the card is always visible;
    /// the full-screen shapes are too, because the overlay is opaque. This is a
    /// plain `true` today and exists so a future floating shape can opt out
    /// without touching the screen itself.
    var endScreenMayCountDown: Bool { true }

    /// Never lock orientation from these screens. iPhone Duo's inner display is
    /// regular in both directions and ignores the lock, so asking for one leaves
    /// the outer display locked after it closes.
    var requestsOrientationLock: Bool { false }
}

// MARK: - Hosting

/// Draws the episode sheet or the end screen for the current shape.
///
/// Kept separate from `PlayerView` so the three shapes share one attach point:
/// `PlayerView` passes the layout and the content, and this decides whether that
/// content is a `.sheet` or an in-picture overlay.
struct PlayerAuxiliaryHost<Panel: View, EndScreen: View>: View {
    let surface: PlayerSurface
    @Binding var showsPanel: Bool
    let panel: () -> Panel
    let showsEndScreen: Bool
    let endScreen: () -> EndScreen

    var body: some View {
        Group {
            if surface.episodesPresentedAsSheet {
                Color.clear
                    .frame(width: 0, height: 0)
                    .sheet(isPresented: $showsPanel) { panel() }
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .bottom) {
                        if showsPanel {
                            panel()
                                .frame(maxHeight: surface.episodePanelMaxHeight)
                                .padding(.horizontal, surface.endScreenInset)
                                .padding(.bottom, surface.endScreenInset)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
            }
        }
        .overlay {
            if showsEndScreen {
                endScreen()
                    .clipShape(RoundedRectangle(cornerRadius: surface.endScreenCornerRadius, style: .continuous))
                    .padding(surface.endScreenInset)
                    .transition(.opacity)
            }
        }
    }
}
