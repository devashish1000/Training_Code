//
//  CaptureView.swift
//  DualPhoneCodingAssistant
//
//  View layer (MVVM) for Phone A ("Capture Mode"). This screen is never
//  meant to be looked at during a real session — Phone A is propped up
//  facing the monitor — but it's still useful to show a live preview +
//  status while setting up / debugging.
//

import SwiftUI
import AVFoundation

struct CaptureView: View {
    @StateObject private var viewModel = CaptureViewModel()

    var body: some View {
        ZStack {
            CameraPreview(session: viewModel.captureSession)
                .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.status.description)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("Detected anchor: \(viewModel.currentAnchor)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.55))
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}

/// Thin `UIViewRepresentable` wrapper so SwiftUI can host an
/// `AVCaptureVideoPreviewLayer`, which is UIKit-only.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Session is set once at creation; nothing to update on state
        // changes for this simple use case.
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

#Preview {
    CaptureView()
}
