//
//  DisplayView.swift
//  DualPhoneCodingAssistant
//
//  View layer (MVVM) for Phone B ("Display Mode"). Pinned anchor/question
//  header at top, and a fully passive (no touch interaction expected)
//  auto-scrolling monospace answer view below it.
//
//  Scroll pacing is a constant lines-per-second rate (not a fixed
//  duration) — a long answer scrolls proportionally longer than a short
//  one, rather than both taking, say, "10 seconds" regardless of length.
//

import SwiftUI

struct DisplayView: View {
    @StateObject private var viewModel = DisplayViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AutoScrollingAnswerView(text: viewModel.currentAnswer?.answerText ?? "")
                // `.id` forces AutoScrollingAnswerView to be fully
                // recreated (fresh scroll state) whenever a new answer
                // arrives, which is exactly the "snap to the new answer
                // from the top" behavior we want.
                .id(viewModel.currentAnswer?.id)
        }
        .background(Color.black.ignoresSafeArea())
        .task { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var header: some View {
        Text(viewModel.currentAnswer?.questionAnchor ?? viewModel.statusText)
            .font(.headline)
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.9))
    }
}

/// Self-contained auto-scrolling monospace text view implementing the
/// "constant lines-per-second, pause at top/bottom, loop forever" pacing.
///
/// Deliberately not a `ScrollView` — there's no user interaction to
/// support (Phone B is passive), so the content is just offset directly
/// and clipped to the visible frame, driven entirely by a background
/// `Task` that alternates `Task.sleep` (for the pauses) and a
/// `withAnimation(.linear(duration:))` scroll segment (for the actual
/// scroll, so pacing tracks content length rather than a fixed time).
private struct AutoScrollingAnswerView: View {
    let text: String

    /// Reading pace. Tune this once you see it running against real
    /// answers — 1.5 lines/sec is a reasonable starting point for
    /// skimming code + explanation without feeling frantic or glacial.
    private let linesPerSecond: Double = 1.5
    private let topPauseSeconds: Double = 1.5
    private let bottomPauseSeconds: Double = 1.5

    /// Approximate monospace line height at the font size below, used to
    /// convert `linesPerSecond` into points/second for the scroll
    /// animation. If you change the font, re-check this against the
    /// font's actual line height (Xcode's SwiftUI preview / a real device
    /// is the easiest way to eyeball it).
    private let approximateLineHeight: CGFloat = 22

    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var loopTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { outerGeometry in
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.green)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { innerGeometry in
                        Color.clear
                            .onAppear { contentHeight = innerGeometry.size.height }
                            .onChange(of: innerGeometry.size.height) { _, newHeight in
                                contentHeight = newHeight
                            }
                    }
                )
                .offset(y: scrollOffset)
                .frame(width: outerGeometry.size.width, height: outerGeometry.size.height, alignment: .top)
                .clipped()
                .onAppear {
                    viewportHeight = outerGeometry.size.height
                    startLoop()
                }
                .onChange(of: outerGeometry.size.height) { _, newHeight in
                    viewportHeight = newHeight
                }
                .onDisappear {
                    loopTask?.cancel()
                }
        }
    }

    /// Runs the pause-scroll-pause cycle forever, until this view is torn
    /// down (which happens automatically when the parent `.id(...)`
    /// changes for a new answer — see `DisplayView`).
    private func startLoop() {
        loopTask?.cancel()
        scrollOffset = 0

        loopTask = Task {
            // Give the GeometryReaders a beat to report real sizes before
            // the first pass computes the scroll distance.
            try? await Task.sleep(nanoseconds: 100_000_000)

            while !Task.isCancelled {
                // Pause at the top so the reader can start reading before
                // motion begins.
                try? await Task.sleep(nanoseconds: UInt64(topPauseSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }

                let scrollableDistance = max(0, contentHeight - viewportHeight)
                if scrollableDistance > 0 {
                    let pointsPerSecond = approximateLineHeight * linesPerSecond
                    let duration = scrollableDistance / pointsPerSecond

                    withAnimation(.linear(duration: duration)) {
                        scrollOffset = -scrollableDistance
                    }
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                }

                // Pause at the bottom before looping back.
                try? await Task.sleep(nanoseconds: UInt64(bottomPauseSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }

                // Loop: snap back to top (no visible reverse-scroll) and
                // repeat indefinitely until a new answer replaces this view.
                scrollOffset = 0
            }
        }
    }
}

#Preview {
    DisplayView()
}
