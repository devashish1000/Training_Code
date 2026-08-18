//
//  QuestionAnswer.swift
//  DualPhoneCodingAssistant
//
//  Model layer (MVVM). Mirrors the single CloudKit record type this app
//  uses: `QuestionAnswer`. Phone A (Capture Mode) creates these records;
//  Phone B (Display Mode) reads them.
//

import Foundation
import CloudKit

/// A single solved coding-practice question, synced between the two
/// phones via CloudKit's private database.
///
/// This is a plain value type used throughout the app's Models/ViewModels/
/// Views layers. `CloudKitService` is the only place that talks `CKRecord`
/// directly — everywhere else works with `QuestionAnswer`.
struct QuestionAnswer: Identifiable, Equatable {

    /// CloudKit record type name. Keep this in one place so the string
    /// literal never has to be re-typed (and re-typo'd) elsewhere.
    static let recordType = "QuestionAnswer"

    /// Field names on the `QuestionAnswer` CloudKit record type.
    /// Referenced by both `toRecord()` and `init(record:)` so the two stay
    /// in sync if a field is ever renamed.
    enum FieldKey {
        static let questionAnchor = "questionAnchor"
        static let answerText = "answerText"
        static let timestamp = "timestamp"
    }

    /// Local identity. Backed by the CKRecord's recordID when this instance
    /// came from CloudKit; a fresh UUID-based CKRecord.ID is generated when
    /// creating a brand-new record before it's ever been saved.
    let id: CKRecord.ID

    /// A short "anchor" string identifying which question this is — e.g.
    /// "Question 3" or a title extracted from the screen. Used both as the
    /// pinned header on Phone B and as the on-device change-detection key
    /// on Phone A (see `QuestionAnchorDetector`).
    var questionAnchor: String

    /// The full solved answer text (explanation + working code) as
    /// returned by the AI. Displayed in Phone B's scrolling code view.
    var answerText: String

    /// When this record was created. Used to sort/identify "the newest
    /// answer" on Phone B.
    var timestamp: Date

    init(
        id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString),
        questionAnchor: String,
        answerText: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.questionAnchor = questionAnchor
        self.answerText = answerText
        self.timestamp = timestamp
    }

    // MARK: - CloudKit conversion

    /// Builds a brand-new `CKRecord` from this value (for saving).
    ///
    /// Uses `self.id` as the record's ID so a re-save of a previously-known
    /// record overwrites in place rather than creating a duplicate.
    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: QuestionAnswer.recordType, recordID: id)
        record[FieldKey.questionAnchor] = questionAnchor as CKRecordValue
        record[FieldKey.answerText] = answerText as CKRecordValue
        record[FieldKey.timestamp] = timestamp as CKRecordValue
        return record
    }

    /// Builds a `QuestionAnswer` from a fetched `CKRecord`. Returns `nil`
    /// if the record is missing an expected field or is the wrong type —
    /// callers should skip/log rather than crash on malformed records.
    init?(record: CKRecord) {
        guard record.recordType == QuestionAnswer.recordType,
              let questionAnchor = record[FieldKey.questionAnchor] as? String,
              let answerText = record[FieldKey.answerText] as? String,
              let timestamp = record[FieldKey.timestamp] as? Date
        else {
            return nil
        }

        self.id = record.recordID
        self.questionAnchor = questionAnchor
        self.answerText = answerText
        self.timestamp = timestamp
    }
}
