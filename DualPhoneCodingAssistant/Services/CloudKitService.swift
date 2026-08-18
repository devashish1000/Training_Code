//
//  CloudKitService.swift
//  DualPhoneCodingAssistant
//
//  Service layer (MVVM). Thin wrapper around CloudKit's private database.
//  Phone A calls `save(_:)`. Phone B calls `startObservingNewAnswers(...)`
//  and gets fed new/changed `QuestionAnswer` records as they arrive.
//
//  Kept deliberately simple for a personal, two-device project — no retry
//  queues, no conflict resolution beyond "last write wins" (CloudKit's
//  default), no offline cache.
//

import Foundation
import CloudKit
import Combine

/// Errors this service can surface. Kept small on purpose.
enum CloudKitServiceError: Error {
    case recordConversionFailed
    case subscriptionSetupFailed(Error)
}

/// Wraps the private CloudKit database for the single `QuestionAnswer`
/// record type this app uses.
///
/// Both phones sign into the **same personal iCloud account**, so both see
/// the same private database — that's the whole sync mechanism. There is
/// no CKShare / public database involved.
final class CloudKitService {

    /// Shared instance — this app only ever needs one CloudKit connection,
    /// so a lightweight singleton avoids threading a service object through
    /// every view for a personal project. (For anything bigger than this,
    /// you'd inject it instead.)
    static let shared = CloudKitService()

    private let container: CKContainer
    private let database: CKDatabase

    /// Publishes every new/changed `QuestionAnswer` record Phone B is told
    /// about, newest last. `DisplayViewModel` subscribes to this and
    /// republishes just the latest one as `@Published` state for the view.
    let newAnswerPublisher = PassthroughSubject<QuestionAnswer, Never>()

    /// Subscription ID kept stable across launches so we don't create a
    /// duplicate `CKQuerySubscription` server-side every time the app runs.
    private let querySubscriptionID = "question-answer-changes-subscription"

    private init(container: CKContainer = .default()) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    // MARK: - Phone A: saving

    /// Saves a newly-solved question/answer pair to the private database.
    /// Called once per genuinely-new question detected by
    /// `QuestionAnchorDetector` + solved by `AIVisionService`.
    func save(_ questionAnswer: QuestionAnswer) async throws {
        let record = questionAnswer.toRecord()
        _ = try await database.save(record)
    }

    // MARK: - Phone B: observing new records

    /// Sets up a `CKQuerySubscription` so CloudKit pushes a silent remote
    /// notification whenever a `QuestionAnswer` record is created. Call
    /// this once, e.g. from `DisplayViewModel.start()`.
    ///
    /// NOTE: for the push half of this to actually fire, the app also
    /// needs the "Background Modes → Remote notifications" capability
    /// enabled in Xcode, and `application(_:didReceiveRemoteNotification:)`
    /// (or the SwiftUI `.onReceive(NotificationCenter...)` equivalent) has
    /// to call `handleRemoteNotification` below. That's an Xcode-only wire-
    /// up step — see the top-level README's manual setup steps.
    ///
    /// As a simpler, fully-in-Swift fallback that needs no push wiring at
    /// all, `DisplayViewModel` also calls `pollForLatestAnswer()` on a
    /// timer. For a personal two-phone project, polling every few seconds
    /// is perfectly reasonable and far less fiddly than getting APNs/
    /// CloudKit push notifications configured correctly — treat the
    /// subscription below as a "nice to have, lower latency" addition, not
    /// a hard requirement.
    func subscribeToNewAnswers() async throws {
        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(
            recordType: QuestionAnswer.recordType,
            predicate: predicate,
            subscriptionID: querySubscriptionID,
            options: [.firesOnRecordCreation]
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // silent push, no banner
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await database.save(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Already exists (e.g. from a previous launch) — that's fine.
        } catch {
            throw CloudKitServiceError.subscriptionSetupFailed(error)
        }
    }

    /// Feed this a `CKQueryNotification`'s recordID (from the push payload)
    /// to fetch the full record and publish it. Wire this up from
    /// `application(_:didReceiveRemoteNotification:)` if/when you set up
    /// the push half described above.
    func handleRemoteNotification(recordID: CKRecord.ID) async {
        do {
            let record = try await database.record(for: recordID)
            if let answer = QuestionAnswer(record: record) {
                newAnswerPublisher.send(answer)
            }
        } catch {
            // Personal project: log and move on. A dropped push just means
            // Phone B waits for the next poll instead.
            print("CloudKitService: failed to fetch pushed record: \(error)")
        }
    }

    /// Simple pull-based fallback: fetch the single most recent
    /// `QuestionAnswer` record. Safe to call on a repeating timer.
    ///
    /// Returns `nil` if there are no records yet, or if the fetch fails
    /// (network hiccup, etc.) — callers should just try again next tick
    /// rather than treating that as fatal.
    func fetchLatestAnswer() async -> QuestionAnswer? {
        let query = CKQuery(
            recordType: QuestionAnswer.recordType,
            predicate: NSPredicate(value: true)
        )
        query.sortDescriptors = [NSSortDescriptor(key: QuestionAnswer.FieldKey.timestamp, ascending: false)]

        do {
            let (matchResults, _) = try await database.records(
                matching: query,
                resultsLimit: 1
            )
            guard let firstResult = matchResults.first else { return nil }
            let record = try firstResult.1.get()
            return QuestionAnswer(record: record)
        } catch {
            print("CloudKitService: fetchLatestAnswer failed: \(error)")
            return nil
        }
    }
}
