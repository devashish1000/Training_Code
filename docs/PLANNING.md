# Planning: Coding-Practice Relay App

## Happy Path

1. User opens a coding-practice question on their computer monitor (e.g. a CodeSignal question panel).
2. Phone A, propped up facing the monitor with its camera on, samples frames every 1-2 sec and runs on-device Vision/OCR to check whether visible text has meaningfully changed.
3. OCR detects a change, extracts the anchor (question number/title from the header), and compares it to the last known anchor. It differs, so this is treated as a new question.
4. Phone A waits for a settle pause (~2-3 sec with no further scroll/tab activity) before acting, so it doesn't fire mid-scroll.
5. Once settled, Phone A captures the current screen image and sends it to the vision-capable AI with the combined judge+solve prompt.
6. The AI recognizes it as a real coding question, extracts it, and returns a full solved answer (or "NONE" if it isn't a question — in which case the cycle just resets and keeps watching).
7. Phone A writes a new `QuestionAnswer` record (questionAnchor, answerText, timestamp) to the shared CloudKit private database.
8. Phone B, subscribed to that record type, receives the new record automatically (no user interaction on either phone).
9. Phone B snaps its display to the top of the new answer text and begins auto-scrolling it at a constant lines-per-second pace, pausing briefly at top and bottom of each loop, repeating until the next answer arrives.
10. User reads the answer on Phone B while working in the practice site on their monitor; while the anchor stays the same (scrolling within the question, switching description/examples/constraints tabs), Phone A does not re-trigger — it just keeps watching for the anchor to change again, at which point the whole cycle repeats from step 3.

## MVP Scope

### Must-have (v1)

- Camera capture loop on Phone A (live preview, periodic frame sampling).
- On-device OCR-based change detection and anchor extraction/comparison.
- Settle timer (~2-3 sec of no-change) before firing the AI call.
- Single AI call per new question that both judges ("is this a real question, else NONE") and solves it.
- CloudKit private-database sync: Phone A writes `QuestionAnswer` records, Phone B subscribes and receives them live.
- Phone B basic auto-scroll display: constant lines-per-second pacing, pause at top/bottom, loops until replaced by the next answer.
- Single Xcode/SwiftUI project with a Capture Mode / Display Mode toggle sharing one CloudKit container.

### Nice-to-have (v2+)

- **Paginated slide-view alternative to scrolling** — a different reading UX; the scrolling display already satisfies the core need of hands-free reading, so this is a UX variant, not a functional gap.
- **History of past Q&A pairs** — useful for review later, but the live "current answer only" flow works without persisting/browsing history; can be added once the live path is proven.
- **Adjustable scroll speed** — a fixed sensible default (constant lines/sec) is enough to validate the concept; making it user-tunable is a refinement, not a blocker.
- **Extra context-frame stitching across scrolls/tabs** — the single settled screenshot is sufficient for most questions; stitching multiple frames (e.g. to capture long descriptions split across scrolls) adds real complexity and is only worth it once single-frame capture proves inadequate in practice.
- **UI polish** — visual styling, animations, settings screens, etc. don't affect whether the core detect -> solve -> sync -> display loop works, so they come last.

## Build & Iteration Order

1. **SwiftUI shell with both modes + CloudKit read/write wired using dummy data.**
   Build the mode toggle (Capture/Display) and get both phones writing/reading a hardcoded `QuestionAnswer` record through the same CloudKit container. This is the "prove it early" magic piece — if sync doesn't work reliably, nothing downstream matters.
   *Done when:* tapping a button (or running a manual test call) on Phone A writes a record, and Phone B's Display Mode receives and shows it live within a few seconds, with no manual refresh.

2. **Phone B display screen with the auto-scroll loop, tested against fake answers.**
   Feed in a few sample answer strings (short and long) and build the constant-lines-per-second auto-scroll with top/bottom pauses and looping, plus the "snap to new answer" behavior when a new CloudKit record arrives.
   *Done when:* short and long dummy answers both scroll at a consistent, readable pace (not fixed-duration), pause correctly at top/bottom, loop indefinitely, and a new incoming record immediately interrupts the loop and restarts display from the top.

3. **Phone A capture loop: camera preview -> local OCR change detection -> AI call -> CloudKit write.**
   Wire up the live camera preview, run on-device OCR on sampled frames, implement anchor extraction/comparison and the settle timer, then hook the settled capture into the real AI call (judge+solve prompt) and write the result via the already-proven CloudKit path from step 1.
   *Done when:* pointing Phone A at any static text/image that resembles a question produces exactly one AI call and one CloudKit write per genuinely new anchor — not per frame, not per scroll — and Phone B (from step 2) displays the result end-to-end without any manual intervention.

4. **Tune the settle timer and anchor-detection logic against a real practice site (e.g. CodeSignal).**
   With the full pipeline working end-to-end on synthetic input, point Phone A at an actual monitor running CodeSignal and adjust settle duration, OCR sensitivity, and anchor-parsing rules based on real scrolling/tab-switching behavior and real question layouts.
   *Done when:* working through several real practice questions in a row — including scrolling within a question, switching between description/examples/constraints tabs, and moving to the next question — triggers exactly one correct AI call/answer per question, with no false triggers and no missed transitions.
