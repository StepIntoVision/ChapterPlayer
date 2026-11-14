//
//  StoryStateStore.swift
//  ChapterPlayer
//
//  THE RUNNING CHAPTER'S MEMORY.
//
//  A reference-typed owner for one `ChapterScript.StoryStateLedger`, so the
//  engine, the gate wait and the navigator all read and write the SAME session
//  rather than passing copies of a value type around and diverging.
//
//  The semantics are not here. What a mutation means, what a condition answers
//  and what resets a session all live in `ChapterScript` — this owns the
//  lifetime and tells anyone who cares that something changed.
//
//  ── A SESSION IS NOT A VISIT ────────────────────────────────────────────────
//
//  `SequenceEngine.play` begins a Sequence VISIT and must never touch this. A
//  CHAPTER PLAYBACK SESSION is the whole run, and it is the only thing that
//  seeds or clears these values. If a visit reset them, walking back into the
//  gallery would forget that the viewer heard the radio.
//
//  ── NOT DOCUMENT STATE ──────────────────────────────────────────────────────
//
//  Nothing here is serialized, synced or undoable. `ChapterDocument.storyState`
//  holds the DEFINITIONS; what a viewer's run has made of them stops when the
//  run does.
//

import Foundation
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "StoryState"
)

@MainActor
@Observable
public final class StoryStateStore {

    /// The current session's values. Read by the condition evaluator directly —
    /// `StoryStateLedger` IS a `StoryStateReading`, so nothing copies it into a
    /// dictionary first.
    public private(set) var ledger = StoryStateLedger()

    /// True between `beginSession` and `endSession`. Distinct from "the ledger
    /// is empty": a Chapter that defines no Story State still has a session.
    public private(set) var isSessionActive = false

    /// Something changed. The gate wait subscribes so a story-condition boundary
    /// resolves the moment the fact it waits for becomes true — event-driven,
    /// never a per-frame poll over the Chapter.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init() {}

    // MARK: - Session lifetime

    /// BEGIN A CHAPTER PLAYBACK SESSION. Every state returns to its authored
    /// initial value.
    public func beginSession(_ definitions: [StoryStateDefinition]) {
        ledger.begin(definitions)
        isSessionActive = true
        if !definitions.isEmpty {
            logger.info("[story] session began with \(definitions.count) Story State(s)")
        }
        onChange?()
    }

    /// END OF SESSION. The run is over; nothing is remembered into the next one.
    public func endSession() {
        guard isSessionActive else { return }
        ledger.end()
        isSessionActive = false
        logger.info("[story] session ended")
        onChange?()
    }

    // MARK: - Resume (OD-98)

    /// What the story remembers right now, for saving with a visit that is
    /// being left (`SuspendedVisit.memorySnapshot`).
    public var memorySnapshot: StoryStateSnapshot { ledger.memorySnapshot }

    /// PUT BACK THE MEMORY A RESUMED VISIT WAS LEFT WITH (OD-98). The owner's
    /// rule: Resume restores the Memory snapshot saved when the visit was
    /// left. Only states this session defines are written, with values of
    /// their own kind (`StoryStateLedger.restore`); `keeping` names states
    /// that are not rolled back. Tells anyone waiting, exactly as a mutation
    /// does, so a Cue waiting on a fact sees the restored one.
    ///
    /// Not an authoring path, and not a session boundary: it neither begins
    /// nor ends a session, and does nothing outside one.
    public func restore(_ snapshot: StoryStateSnapshot, keeping: Set<String> = []) {
        guard isSessionActive else { return }
        let before = ledger.memorySnapshot
        ledger.restore(snapshot, keeping: keeping)
        guard ledger.memorySnapshot != before else { return }
        logger.info("[story] Resume restored the Memory saved when the visit was left")
        onChange?()
    }

    // MARK: - Mutation

    /// Apply one authored change and tell anyone waiting.
    ///
    /// A refusal is LOGGED, not silently swallowed: a mutation naming a deleted
    /// Story State is an authoring problem, and the only symptom on device would
    /// otherwise be a gate that never opens.
    @discardableResult
    public func apply(_ mutation: StoryStateMutation) -> Bool {
        switch ledger.apply(mutation) {
        case .success(let value):
            logger.info("[story] \(mutation.stateId) is now \(String(describing: value))")
            onChange?()
            return true
        case .failure(let refusal):
            logger.warning("[story] \(refusal.message)")
            return false
        }
    }
}
