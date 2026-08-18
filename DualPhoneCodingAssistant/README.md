# Dual Phone Coding Assistant

A personal, native-only iOS SwiftUI app for a two-iPhone coding-practice setup.

## What this is

Two personal iPhones are used side by side during coding-practice sessions
(e.g. working through CodeSignal-style questions on a monitor):

- **Phone A ("Capture Mode")** is propped facing the monitor with its camera
  on. It is never touched or looked at during a session. It watches the
  screen, and when it detects a genuinely *new* coding question, it captures
  a frame, sends it to a vision-capable AI (Claude) to solve, and writes the
  result to CloudKit.
- **Phone B ("Display Mode")** is the only screen the user actually looks at.
  It passively listens for new answers via CloudKit and auto-scrolls through
  them, hands-free.

Both roles live in **one single-target SwiftUI app**; which behavior a given
phone exhibits is controlled by a persisted mode toggle picked once on first
launch (see `Views/ModeSelectionView.swift`).

This is a **personal project for one person's own two iPhones**. There is no
App Store distribution, no multi-user support, and no production hardening
beyond "works reliably for personal use." Code is intentionally lightweight
— MVVM-organized, but not over-engineered.

## Tech stack

- SwiftUI (iOS), Swift concurrency (`async`/`await`)
- CloudKit (private database) for syncing an answer from Phone A to Phone B
- Apple's `Vision` framework (`VNRecognizeTextRequest`) for cheap, on-device
  OCR / change detection, so the paid AI call only fires once per genuinely
  new question
- `AVFoundation` for the live camera preview on Phone A
- A plain `URLSession`-based client for Anthropic's Claude Messages API
  (vision-capable model) — no third-party SDK dependency

## Important: this code was written without Xcode/a Mac

This project was scaffolded in a cloud container that has **no Xcode and no
macOS available** — it has never been opened in Xcode, compiled, or run.
Treat everything here as a structured **starting point**, not a verified
build. Expect to fix minor issues (import ordering, small API mismatches,
Info.plist keys, entitlement wiring) the first time you open it on a Mac.

## Opening this project in Xcode (on your Mac)

This repo currently contains loose Swift source files organized by MVVM
folder — it is **not yet an `.xcodeproj`/`.xcodeworkspace`**. On your Mac:

1. Open Xcode → **File → New → Project… → iOS → App**.
2. Name it (e.g. `DualPhoneCodingAssistant`), interface: **SwiftUI**,
   language: **Swift**. Save it wherever you like — you can create it right
   inside (or alongside) this folder.
3. Delete the placeholder `ContentView.swift` Xcode generates, and drag the
   `Models/`, `Views/`, `ViewModels/`, and `Services/` folders from this
   repo into the new Xcode project (check "Copy items if needed" and "Create
   groups").
4. Point your app's entry-point `App` struct's root view at
   `ModeSelectionView()` (see that file's doc comment).
5. Build once (⌘B) and fix whatever the compiler flags — this codebase has
   not been compiled before.

## Manual setup steps you'll need to do in Xcode

These cannot be done from source files alone — they require the Xcode UI
and your Apple ID:

1. **Signing & Capabilities → Team**: set your personal Apple Developer
   team (a free Apple ID account is enough for on-device personal builds).
2. **Signing & Capabilities → + Capability → iCloud**: enable iCloud, check
   **CloudKit**, and create/select a CloudKit container (e.g.
   `iCloud.com.yourname.DualPhoneCodingAssistant`). This also adds the
   `com.apple.developer.icloud-services` entitlement automatically.
3. **CloudKit Dashboard** (https://icloud.developer.apple.com/dashboard/):
   the `QuestionAnswer` record type and its fields will auto-create the
   first time Phone A saves a record from a debug build, but you can also
   define them by hand there ahead of time — see `Models/QuestionAnswer.swift`
   for the exact field names/types.
4. **Info.plist**: add `NSCameraUsageDescription` (camera permission string)
   for Phone A's capture flow.
5. **AI API key**: add your Anthropic API key somewhere Xcode ships but git
   does not track — e.g. a `Secrets.plist` / `Config.xcconfig` entry read at
   runtime. See the `TODO` in `Services/AIVisionService.swift` for the exact
   key it expects. **Never hardcode the key in a `.swift` file.**
6. Build and run once to Phone A and once to Phone B (two physical devices,
   or a device + simulator for a first smoke test — though the camera flow
   needs a real device). On first run each device will prompt for iCloud
   and camera permissions; both phones must be signed into the **same**
   iCloud account for the private CloudKit database to sync between them.

## Recommended order of operations (once on your Mac)

Because the riskiest, hardest-to-debug-blind part of this whole idea is
"does Claude actually solve the on-screen question well from a photo of a
monitor," **validate that first, before touching Xcode at all**:

1. Follow `Scripts/manual_ai_test.md` — a copy-paste `curl` test against the
   real Claude API using a real screenshot, no Xcode required. Confirm the
   AI reliably gives a correct, well-formatted solved answer.
2. Once step 1 looks good, do the Xcode project setup above.
3. Bring up **Display Mode (Phone B)** first and test it by manually writing
   a `QuestionAnswer` test record from the CloudKit Dashboard — confirms the
   CloudKit subscription + auto-scroll UI work before Capture Mode exists.
4. Bring up **Capture Mode (Phone A)**: verify the camera preview, then the
   OCR/anchor-change detector in isolation (log what it detects, don't wire
   the AI call yet), then finally wire in the AI call + CloudKit save.
5. Run both phones side by side for a real practice session and tune the
   OCR anchor heuristic (see the comment in
   `Services/QuestionAnchorDetector.swift`) and the settle-timer duration
   against how the real target website behaves.

## Project layout

```
DualPhoneCodingAssistant/
├── README.md
├── Models/
│   └── QuestionAnswer.swift
├── Services/
│   ├── CloudKitService.swift
│   ├── AIVisionService.swift
│   └── QuestionAnchorDetector.swift
├── ViewModels/
│   ├── CaptureViewModel.swift
│   └── DisplayViewModel.swift
├── Views/
│   ├── CaptureView.swift
│   ├── DisplayView.swift
│   └── ModeSelectionView.swift
└── Scripts/
    └── manual_ai_test.md
```
