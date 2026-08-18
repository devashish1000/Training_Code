//
//  ModeSelectionView.swift
//  DualPhoneCodingAssistant
//
//  View layer (MVVM). Root view of the app. Both phones run the exact
//  same app/binary — this screen is where each physical device is told
//  once which role it plays. The choice is persisted via `@AppStorage`,
//  so after the first launch each phone just boots straight into its
//  mode.
//
//  Point your `App` struct's `WindowGroup` at `ModeSelectionView()`, e.g.:
//
//      @main
//      struct DualPhoneCodingAssistantApp: App {
//          var body: some Scene {
//              WindowGroup {
//                  ModeSelectionView()
//              }
//          }
//      }
//

import SwiftUI

/// The two roles a phone running this app can take on. Raw-string backed
/// so it stores cleanly in `@AppStorage`.
enum AppMode: String {
    case captureMode
    case displayMode
}

struct ModeSelectionView: View {
    /// `nil`/unset (no stored value yet) is represented as an empty
    /// string here, since `@AppStorage` needs a concrete default for
    /// `RawRepresentable` enums; `resolvedMode` below turns that back
    /// into an `AppMode?`.
    @AppStorage("appMode") private var storedModeRawValue: String = ""

    private var resolvedMode: AppMode? {
        AppMode(rawValue: storedModeRawValue)
    }

    var body: some View {
        Group {
            switch resolvedMode {
            case .captureMode:
                CaptureView()
            case .displayMode:
                DisplayView()
            case nil:
                modePicker
            }
        }
    }

    private var modePicker: some View {
        VStack(spacing: 24) {
            Text("Dual Phone Coding Assistant")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Choose what this phone does. This is remembered — you won't be asked again on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button {
                    storedModeRawValue = AppMode.captureMode.rawValue
                } label: {
                    Label("Capture Mode (Phone A)", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    storedModeRawValue = AppMode.displayMode.rawValue
                } label: {
                    Label("Display Mode (Phone B)", systemImage: "text.below.photo.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
        }
        .padding()
    }
}

#Preview {
    ModeSelectionView()
}
