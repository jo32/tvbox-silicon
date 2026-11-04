//
//  SeriesEndScreen.swift
//  TVBox
//
//  Shown when the last episode of a video finishes.
//
//  Before this, `onPlaybackEnded` jumped straight to the next episode or did
//  nothing — there was no "what next" step. The requirement asks for a
//  recommendation screen that prefers the same source and the same show (a
//  different season of it, 红果 style) and, after ten seconds without a choice,
//  starts the top suggestion on its own.
//
//  The countdown only ever targets a `.nextSeason` row. Auto-playing an
//  unrelated title would be a surprise the viewer did not ask for, so when no
//  next season exists the screen simply waits with no countdown.
//

import SwiftUI
import TVCore

struct SeriesEndScreen: View {
    let finishedTitle: String
    let suggestions: [SeriesSuggestion]
    let replay: @MainActor () -> Void
    let choose: @MainActor (SeriesSuggestion) -> Void
    let dismiss: @MainActor () -> Void

    @State private var remaining = SeriesSuggestionRanker.autoAdvanceSeconds
    @State private var counting = false
    @State private var timer: Task<Void, Never>?

    private var autoTarget: SeriesSuggestion? {
        SeriesSuggestionRanker.autoAdvanceTarget(in: suggestions)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    title
                    if suggestions.isEmpty {
                        emptyState
                    } else {
                        suggestionGrid
                    }
                    actions
                }
                .padding(22)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .onAppear { startCountdownIfNeeded() }
        .onDisappear { timer?.cancel() }
        .accessibilityElement(children: .contain)
    }

    // MARK: Title

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Finished %@", finishedTitle))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            if let target = autoTarget, counting {
                Text(L10n.text("Playing %@ in %d s", target.video.name, remaining))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.numericText(countsDown: true))
            } else if !suggestions.isEmpty {
                Text(L10n.text("Pick something to watch next."))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    // MARK: Suggestions

    private var suggestionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 14) {
            ForEach(suggestions) { suggestion in
                suggestionCard(suggestion)
            }
        }
    }

    private func suggestionCard(_ suggestion: SeriesSuggestion) -> some View {
        Button {
            timer?.cancel()
            choose(suggestion)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                poster(suggestion.video)
                Text(suggestion.video.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(suggestion.badge)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(suggestion.kind == .nextSeason
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.9))
                                    : AnyShapeStyle(Color.white.opacity(0.18)))
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
                    if let year = suggestion.video.year {
                        Text(year).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                if !suggestion.sourceName.isEmpty {
                    Text(suggestion.sourceName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func poster(_ video: Video) -> some View {
        Group {
            if let address = video.poster {
                AsyncImage(url: address) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                }
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        Text(L10n.text("Nothing else from this source was found."))
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                timer?.cancel()
                replay()
            } label: {
                Label(L10n.text("Replay"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)

            Button {
                timer?.cancel()
                dismiss()
            } label: {
                Label(L10n.text("Done"), systemImage: "xmark")
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)

            if autoTarget != nil && counting {
                Button {
                    timer?.cancel()
                    counting = false
                } label: {
                    Text(L10n.text("Stay"))
                }
                .buttonStyle(.bordered)
            }
        }
        .tint(.white)
    }

    // MARK: Countdown

    private func startCountdownIfNeeded() {
        guard autoTarget != nil else { return }
        counting = true
        remaining = SeriesSuggestionRanker.autoAdvanceSeconds
        timer?.cancel()
        timer = Task { @MainActor in
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
            }
            if Task.isCancelled { return }
            guard let target = autoTarget else { return }
            counting = false
            choose(target)
        }
    }
}
