//
//  CaptureViewModel.swift
//  DualPhoneCodingAssistant
//
//  ViewModel layer (MVVM) for Phone A ("Capture Mode"). Owns the camera
//  session and wires together: camera frames -> QuestionAnchorDetector
//  (on-device OCR + settle timer) -> AIVisionService (one Claude call per
//  new question) -> CloudKitService (sync the answer to Phone B).
//
//  `CaptureView` observes this via `@Published` properties and shouldn't
//  need to know any of the above pipeline details.
//

import Foundation
import AVFoundation
import UIKit
import CoreImage

/// Human-readable state for the (never-looked-at, but still useful for
/// debugging over AirPlay/Xcode console) status text shown on Phone A.
enum CaptureStatus: Equatable {
    case idle
    case watching
    case solving(anchor: String)
    case saved(anchor: String)
    case error(String)

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .watching: return "Watching for a question…"
        case .solving(let anchor): return "New question detected (\(anchor)) — solving…"
        case .saved(let anchor): return "Saved answer for \(anchor)"
        case .error(let message): return "Error: \(message)"
        }
    }
}

/// Drives Phone A's capture pipeline. Marked `@MainActor` so all
/// `@Published` state mutations and the downstream AI/CloudKit calls are
/// naturally serialized on the main actor; only the
/// `AVCaptureVideoDataOutputSampleBufferDelegate` callback (which AVFoundation
/// invokes on a background queue) is `nonisolated`, and it hops back to the
/// main actor immediately for anything beyond the cheap OCR pass.
@MainActor
final class CaptureViewModel: NSObject, ObservableObject {

    @Published private(set) var status: CaptureStatus = .idle
    @Published private(set) var currentAnchor: String = "—"

    /// Live camera session, exposed so `CaptureView` can wrap it in an
    /// `AVCaptureVideoPreviewLayer`.
    let captureSession = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.dualphonecodingassistant.capture-session")
    private let detector = QuestionAnchorDetector()
    private let aiService = AIVisionService.shared
    private let cloudKitService = CloudKitService.shared
    private let ciContext = CIContext()

    /// Frame sampling throttle — we don't need to run OCR on every camera
    /// frame (30-60/sec); once every 1-2 seconds is plenty to catch a
    /// question change quickly while keeping CPU/battery reasonable for a
    /// phone that runs unattended for a whole practice session.
    private let sampleInterval: TimeInterval = 1.5
    private var lastSampleTime: Date = .distantPast

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        status = .watching
        sessionQueue.async { [weak self] in
            self?.configureSessionIfNeeded()
            self?.captureSession.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    private func configureSessionIfNeeded() {
        guard captureSession.inputs.isEmpty else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input)
        else {
            captureSession.commitConfiguration()
            Task { @MainActor in self.status = .error("Camera unavailable") }
            return
        }
        captureSession.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()
    }

    // MARK: - Per-frame handling

    /// Called (on the main actor) once per sampled frame with the OCR'd
    /// text lines for that frame and a still-image snapshot in case this
    /// turns out to be the frame whose anchor settles.
    private func handleSampledFrame(lines: [String], snapshot: UIImage) {
        let anchor = detector.extractAnchor(fromLines: lines)
        currentAnchor = anchor ?? "(no question detected)"

        detector.noteDetectedAnchor(anchor) { [weak self] settledAnchor in
            self?.handleSettledAnchor(settledAnchor, image: snapshot)
        }
    }

    /// Called once per genuinely-new, settled question. Fires the single
    /// AI vision call and, if it comes back with a real answer, saves it
    /// to CloudKit for Phone B to pick up.
    private func handleSettledAnchor(_ anchor: String, image: UIImage) {
        status = .solving(anchor: anchor)

        Task {
            do {
                guard let answerText = try await aiService.solveQuestion(from: image) else {
                    // AI decided this wasn't actually a coding question
                    // (replied "NONE") — go back to watching.
                    status = .watching
                    return
                }

                let questionAnswer = QuestionAnswer(questionAnchor: anchor, answerText: answerText)
                try await cloudKitService.save(questionAnswer)
                status = .saved(anchor: anchor)
            } catch {
                status = .error(String(describing: error))
            }
        }
    }

    // MARK: - Pixel buffer -> UIImage

    private func image(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// AVFoundation calls this on `sessionQueue`, not the main actor —
    /// hence `nonisolated`. We do the cheap parts (throttle check + OCR,
    /// which is itself a local/on-device Vision call) here, then hop to
    /// the main actor with just the small result (text lines + a snapshot
    /// image) for everything that touches `@Published` state or kicks off
    /// the AI/CloudKit calls.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // NOTE: CVPixelBuffer isn't formally `Sendable`; under Swift 6's
        // strict concurrency checking this capture may produce a warning.
        // In practice it's safe here (the buffer isn't touched again on
        // this queue after this call), but if you turn on strict
        // concurrency checking and it errors instead of warns, do the OCR
        // pass synchronously on `sessionQueue` first and only hop to
        // `@MainActor` with the already-extracted `[String]` + `UIImage`.
        Task { @MainActor in
            let now = Date()
            guard now.timeIntervalSince(self.lastSampleTime) >= self.sampleInterval else { return }
            self.lastSampleTime = now

            guard let lines = try? self.detector.recognizeTextLines(in: pixelBuffer),
                  let snapshot = self.image(from: pixelBuffer) else { return }

            self.handleSampledFrame(lines: lines, snapshot: snapshot)
        }
    }
}
