//
//  StoryDecisionHold.swift
//  ChapterPlayer
//
//  A "CONTINUE BY THE STORY" ENDING THAT FOUND NO MATCH (OD-42).
//
//  A Sequence ends on a decision: "if they have the key, go to the Vault".
//  When no case matches and there is no Otherwise, the navigator answers
//  `.stay`, and the Sequence holds on its end state (OD-45). The owner's
//  rule: while it holds there, ANY Memory change re-checks the cases, and
//  the story moves on as soon as one matches.
//
//  This is the arithmetic of that rule, off the RealityKit path so it can
//  be tested on its own: which endings can be held this way, and whether
//  what the story now remembers lets one go. The decision itself is still
//  the navigator's, through `ChapterPlayerCore.performCompletion`.
//

import Foundation
import ChapterScript

public struct StoryDecisionHold: Sendable, Equatable {

    /// The authored ending that is waiting.
    public let completion: CompletionActionDTO
    /// The Sequence that ended on it.
    public let sequenceId: String
    /// Where that Sequence stopped, which is its end.
    public let endPosition: TimeInterval

    public init(completion: CompletionActionDTO, sequenceId: String,
                endPosition: TimeInterval) {
        self.completion = completion
        self.sequenceId = sequenceId
        self.endPosition = endPosition
    }

    /// The hold a finished Sequence is now in, or nil when it is not one.
    ///
    /// Only a decision ending (`.branch`) that the navigator answered with
    /// `.stay` holds this way. Hold, a plain Go To, a refusal or an ending
    /// that moved on have nothing to re-check: Memory cannot change what they
    /// mean.
    public static func holding(after completion: CompletionActionDTO,
                               from sequenceId: String,
                               endingAt position: TimeInterval,
                               outcome: NavigationOutcome) -> StoryDecisionHold? {
        guard outcome == .stay,
              case .branch? = NavigationIntent.forCompletion(completion) else { return nil }
        return StoryDecisionHold(completion: completion, sequenceId: sequenceId,
                                 endPosition: position)
    }

    /// Does what the story remembers now match a case (or reach an
    /// Otherwise)? Asks the same resolution the navigator uses, so the two
    /// cannot disagree about whether the story may go.
    public func movesOn(in state: some StoryStateReading) -> Bool {
        guard let intent = NavigationIntent.forCompletion(completion) else { return false }
        return intent.resolving(in: state) != nil
    }
}
