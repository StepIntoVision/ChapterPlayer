//
//  ChapterPlayerCore+HostMessage.swift
//  ChapterPlayer
//
//  THE ORCHESTRATOR MESSAGE (OD-49, TODO-108).
//
//  An Orchestrator Cue waits for a message from the host app, never for the
//  viewer, and nothing sent that message, so on the headset such a Cue waited
//  out its Timeout. This is the one place a host message reaches the runtime:
//  a Maestro host sends it over the live link (`event: orchestrator` on the
//  Mac's SSE stream), and MaestroVision's Chapter Preview Continue stands in
//  for it, as the Mac preview banner's Continue does.
//
//  The decision is ChapterScript's (`GateActivation.hostMessageAnswer`, the
//  same rule as `satisfiedByHostMessage`), read against the Cue AS AUTHORED,
//  so a Choice Cue is never continued by a plain message and a Cue that also
//  needs Memory still needs it.
//

import Foundation
import OSLog
import ChapterScript

private let hostMessageLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "HostMessage"
)

extension ChapterPlayerCore {

    /// The Cue the story is waiting at, as authored, or nil when nothing
    /// waits.
    public var waitingCueAsAuthored: SegmentGateDTO? {
        guard sequenceEngine.isWaiting, let gate = sequenceEngine.currentGate else { return nil }
        return authoredGate(for: gate)
    }

    /// What a host message would do at the Cue the story is waiting at, now.
    public func hostMessageAnswer() -> GateActivation.HostMessageAnswer {
        GateActivation.hostMessageAnswer(waitingCueAsAuthored, in: storyState.ledger)
    }

    /// **A host message arrived.** Continues the waiting Orchestrator or
    /// Either Cue when the rule allows it (a paused transport resumes, as for
    /// a tap that answers a Cue), and otherwise changes nothing. Returns what
    /// it came to, so a host can say why nothing continued.
    @discardableResult
    public func receiveHostMessage() -> GateActivation.HostMessageAnswer {
        let answer = hostMessageAnswer()
        guard answer == .continues else {
            hostMessageLogger.info("[host] an orchestrator message continued nothing: \(String(describing: answer), privacy: .public)")
            return answer
        }
        hostMessageLogger.info("[host] an orchestrator message continued the Cue")
        sequenceEngine.satisfyGate()
        return answer
    }
}
