//
//  QuestionAnchorDetector.swift
//  DualPhoneCodingAssistant
//
//  Service layer (MVVM). Cheap, fully on-device change detection for
//  Phone A's capture loop, so the paid Claude vision call only fires once
//  per genuinely new question rather than on every sampled frame.
//
//  Pipeline: camera frame -> on-device OCR (Vision) -> extract a short
//  "anchor" string identifying the question -> debounce/settle-timer ->
//  fire callback once the anchor has been stable for N seconds.
//

import Foundation
import Vision
import CoreVideo

/// Detects text on a captured frame and derives a short "anchor" string
/// (e.g. "Question 3") used to tell whether the on-screen question has
/// changed. Also owns the "settle timer": rather than reacting to every
/// single frame (OCR is noisy — a partial repaint can misread a line), it
/// waits for the anchor to stay the same for a short window before
/// declaring "this is a real, stable new question."
final class QuestionAnchorDetector {

    /// How long the *same* anchor must be seen with no changes before
    /// we consider it "settled" and worth spending an AI call on.
    /// 2-3 seconds is a reasonable starting point for a page that finishes
    /// rendering/scrolling shortly after a question loads; tune against
    /// the real target site once you're testing on-device.
    private let settleDuration: TimeInterval

    /// The most recently *seen* anchor, updated on every OCR pass
    /// regardless of whether it has settled yet.
    private var currentCandidateAnchor: String?

    /// The last anchor we actually fired `onSettled` for. Prevents firing
    /// again for a question we've already solved (e.g. if the same anchor
    /// keeps getting reported across many frames after settling).
    private var lastFiredAnchor: String?

    /// The in-flight settle-timer task, if any. Restarted (old one
    /// cancelled) every time the candidate anchor changes.
    private var settleTask: Task<Void, Never>?

    init(settleDuration: TimeInterval = 2.5) {
        self.settleDuration = settleDuration
    }

    // MARK: - OCR

    /// Runs on-device text recognition on a captured camera frame.
    /// Returns the recognized lines of text, roughly top-to-bottom as
    /// Vision orders its observations.
    ///
    /// This is the "cheap/local" step — no network call, so it's fine to
    /// run this every 1-2 seconds as new frames are sampled.
    func recognizeTextLines(in pixelBuffer: CVPixelBuffer) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    // MARK: - Anchor extraction

    /// Derives a short "anchor" string for the question currently on
    /// screen, from OCR'd lines of text.
    ///
    /// NOTE: this is a simple heuristic (first line matching something
    /// like "Question 3" / "Problem #12" / "Task 5", searched near the top
    /// of the recognized text) and will almost certainly need real-world
    /// tuning once you see how your actual target site (e.g. a
    /// CodeSignal-style layout) renders its question headers — font,
    /// exact wording, and position on screen all affect what Vision
    /// recognizes and in what order. Treat this function as the first
    /// thing to adjust if change-detection misses new questions or fires
    /// on things that aren't new questions.
    func extractAnchor(fromLines lines: [String]) -> String? {
        let anchorPattern = #"(?i)^\s*(question|problem|task)\s*#?\s*\d+"#

        if let matchingLine = lines.prefix(10).first(where: {
            $0.range(of: anchorPattern, options: .regularExpression) != nil
        }) {
            return matchingLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: if nothing matches the "Question N" style pattern,
        // fall back to the first non-blank recognized line. It's a weaker
        // signal (more prone to false "changes" from unrelated on-screen
        // text), but keeps the detector functional against layouts that
        // don't use that exact wording, rather than never firing at all.
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Settle timer / debounce

    /// Feed this every time a frame is sampled and OCR'd (every 1-2
    /// seconds from `CaptureViewModel`), with whatever anchor
    /// `extractAnchor` returned for that frame (may be `nil` if no text
    /// was recognized at all — pass `nil` through, it's treated as "no
    /// question visible").
    ///
    /// If the anchor differs from what we're currently tracking, the
    /// settle timer restarts. Once `settleDuration` elapses with no
    /// further changes, `onSettled` fires exactly once for that anchor
    /// (never twice in a row for the same anchor).
    ///
    /// `onSettled` is `@MainActor` because it's expected to feed straight
    /// into `CaptureViewModel`'s `@Published` state / trigger the (also
    /// main-actor) AI + CloudKit calls — this keeps the whole downstream
    /// chain on the main actor without extra hops at each call site.
    func noteDetectedAnchor(_ anchor: String?, onSettled: @escaping @MainActor (String) -> Void) {
        guard let anchor, !anchor.isEmpty else {
            // No question currently visible — stop any pending timer, but
            // don't clear `lastFiredAnchor`: if the same question anchor
            // reappears later (e.g. a transient OCR miss), we don't want
            // to re-fire the AI call for something we've already solved.
            settleTask?.cancel()
            currentCandidateAnchor = nil
            return
        }

        guard anchor != currentCandidateAnchor else {
            // Same anchor as last frame — a settle timer is already
            // running (or already fired) for it. Nothing to do.
            return
        }

        currentCandidateAnchor = anchor
        settleTask?.cancel()

        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(self.settleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.currentCandidateAnchor == anchor else { return }
            guard self.lastFiredAnchor != anchor else { return }

            self.lastFiredAnchor = anchor
            onSettled(anchor)
        }
    }

    /// Resets all tracking state, e.g. if `CaptureViewModel` wants to
    /// force-allow re-solving the current question again.
    func reset() {
        settleTask?.cancel()
        settleTask = nil
        currentCandidateAnchor = nil
        lastFiredAnchor = nil
    }
}
