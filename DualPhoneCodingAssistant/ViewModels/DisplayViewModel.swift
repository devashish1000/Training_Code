//
//  DisplayViewModel.swift
//  DualPhoneCodingAssistant
//
//  ViewModel layer (MVVM) for Phone B ("Display Mode"). Listens for new
//  QuestionAnswer records via CloudKitService and exposes the current one
//  as @Published state for DisplayView to render, auto-scrolling.
//

import Foundation
import Combine

/// Drives Phone B's passive display. No user interaction is expected —
/// this view model exists purely to get new CloudKit data onto screen.
@MainActor
final class DisplayViewModel: ObservableObject {

    /// The question/answer currently shown. `DisplayView` resets its
    /// auto-scroll position to the top whenever this changes (see that
    /// view's `.onChange(of:)`).
    @Published private(set) var currentAnswer: QuestionAnswer?

    /// Simple connectivity/status text, useful if something looks wrong
    /// during a session (this phone *is* looked at, so a small status
    /// line is worth keeping around for peace of mind).
    @Published private(set) var statusText: String = "Waiting for first question…"

    private let cloudKitService = CloudKitService.shared
    private var cancellables = Set<AnyCancellable>()

    /// Fallback polling interval — see the comment on
    /// `CloudKitService.subscribeToNewAnswers()` for why polling is the
    /// simpler, recommended path for a personal two-device project even
    /// though a push-based subscription is also set up.
    private let pollInterval: TimeInterval = 5
    private var pollTask: Task<Void, Never>?

    func start() {
        // Push-based updates (best-effort — requires the remote-notification
        // capability + AppDelegate wiring described in CloudKitService).
        cloudKitService.newAnswerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] answer in
                self?.apply(answer)
            }
            .store(in: &cancellables)

        Task {
            try? await cloudKitService.subscribeToNewAnswers()
        }

        // Pull-based fallback — guarantees this view eventually catches up
        // even if push notifications aren't configured yet.
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if let latest = await cloudKitService.fetchLatestAnswer() {
                    apply(latest)
                }
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        cancellables.removeAll()
    }

    /// Applies a newly-received answer, but only if it's actually new —
    /// avoids re-triggering DisplayView's "snap to top" reset every poll
    /// tick for an answer we're already showing.
    private func apply(_ answer: QuestionAnswer) {
        guard answer.id != currentAnswer?.id else { return }
        currentAnswer = answer
        statusText = "Showing: \(answer.questionAnchor)"
    }
}
