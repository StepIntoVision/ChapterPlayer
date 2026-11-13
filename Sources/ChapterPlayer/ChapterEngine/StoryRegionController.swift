//
//  StoryRegionController.swift
//  ChapterPlayer
//
//  EXPLORE, ON DEVICE.
//
//  `ChapterScript.StoryRegionRuntime` is the arithmetic — which region is
//  active, whether its exit resolved, whether the story is playing its first
//  pass or holding at the boundary. This is what that arithmetic touches:
//  the fallback timer, the continuation behaviors, and the one call that
//  releases the story.
//
//  WHAT THIS DELIBERATELY DOES NOT OWN: the hold itself.
//
//  A region's exit is a GATE on the segment that ends at its boundary, and the
//  engine already parks `sequenceAnimationTime` at a segment's end while a gate
//  waits — animation, audio automation and backdrop cues have held there since
//  gates were wired. So Explore's hold is the mechanism the runtime already
//  had, and this file adds no second way to stop the story. Resolving the exit
//  is `satisfyGate()`, the same call a tap has always made.
//
//  That is also why there is no second detector: the exit is a `SegmentGate`, so
//  `GateDetectionController` and `SpatialTriggerDetector` do the sensing, and
//  an accessible activation of the same interaction releases the region exactly
//  as a physical one does.
//
//  THE CLOCK THIS OWNS IS THE RUNTIME ONE.
//
//  `elapsed` comes from the engine's own pause-aware playback clock, never from
//  `Date()` and never from a `Task.sleep`. A paused experience does not age its
//  region, and an app that was suspended for a minute does not come back to
//  find the Explore span expired. The fallback timer is polled on that clock
//  rather than scheduled, so there is nothing to cancel and nothing to leak.
//

import Foundation
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "StoryRegions"
)

@MainActor
@Observable
public final class StoryRegionController {

    // MARK: - Wiring

    /// Releases the story. Wired to `SequenceEngine.satisfyGate` — the SAME
    /// call a tap makes, so there is one way out of a hold.
    @ObservationIgnored public var releaseStory: (() -> Void)?

    /// The runtime's pause-aware playback clock, in seconds. Supplied by the
    /// engine (`totalElapsed`), which already subtracts paused time.
    @ObservationIgnored public var runtimeClock: (() -> TimeInterval)?

    /// The authored Sequence clock, which the engine clamps at a boundary
    /// during a gate wait. That clamping IS the hold.
    @ObservationIgnored public var authoredClock: (() -> TimeInterval)?

    /// Applies a continuation behavior to one target. Wired by
    /// `ChapterPlayerCore` to the executors; nil in tests.
    @ObservationIgnored public var applyContinuation:
        ((StoryContinuationTarget, StoryContinuationBehavior, ContinuationPhase) -> Void)?

    /// Fades one target's gain to silence over N seconds as the story
    /// resumes. Wired to the runtime's existing per-channel gain command —
    /// there is no region-owned gain engine.
    @ObservationIgnored public var applyExitFade:
        ((StoryContinuationTarget, TimeInterval) -> Void)?

    /// The story has just parked at `region`'s boundary and every authored
    /// continuation has been applied. This is where the host applies the
    /// DEFAULT — content the author said nothing about — which the region
    /// cannot enumerate because it owns no clip.
    @ObservationIgnored public var holdDidBegin: ((StoryRegion) -> Void)?

    /// The hold is over, for ANY reason: the exit resolved, playback was
    /// interrupted, the engine moved past the boundary, or the visit ended.
    /// The host releases whatever it paused. Called exactly once per
    /// `holdDidBegin`, which is the guarantee a paused player needs — a
    /// release that only ran on the resolved path would leave a frozen
    /// picture behind every seek out of a region.
    @ObservationIgnored public var holdDidEnd: (() -> Void)?

    /// Loop overlay for an entity's animation: the sample time an explicitly
    /// looping entity should be evaluated at while the story is held.
    @ObservationIgnored public var setAnimationLoopOverride:
        ((_ entity: String, _ sampleTime: Double?) -> Void)?

    /// When a continuation is applied, and why.
    public enum ContinuationPhase: Sendable, Equatable {
        /// The authored first pass reached the boundary and the story is now
        /// holding. Start whatever was authored to keep going.
        case enteringHold
        /// The region resolved. Put everything back to ordinary evaluation.
        case leavingHold
    }

    // MARK: - Observable state

    /// The region the runtime is inside, if any. Small and changes at most
    /// twice per region, so it is safe to observe.
    public private(set) var active: StoryRegionRuntime?

    /// Seconds the story has been parked at the boundary — what a runtime
    /// indicator shows. Published on CHANGE at a coarse granularity, never per
    /// frame: see `tick`.
    public private(set) var displayDwell: Int = 0

    /// Whether the story is currently held. Drives host UI ("Exploring").
    public private(set) var isHolding: Bool = false

    @ObservationIgnored private var regions: [StoryRegion] = []
    /// Loop overrides installed this hold, so `leavingHold` removes exactly
    /// what `enteringHold` added.
    @ObservationIgnored private var installedLoops: Set<String> = []
    /// The active region has let the story go. Once per region execution:
    /// the tick after a release must not release again.
    @ObservationIgnored private var didRelease = false

    public init() {}

    // MARK: - Sequence lifecycle

    /// Adopt a sequence's authored regions. Called when a Sequence Visit begins.
    public func begin(regions: [StoryRegion]) {
        teardown()
        self.regions = StoryRegionTimeline.sorted(regions)
        if !self.regions.isEmpty {
            logger.info("Sequence has \(self.regions.count) Explore region(s)")
        }
    }

    /// End of visit. Every transient fact goes; nothing here was ever authored.
    public func teardown() {
        endHoldIfNeeded()
        clearLoopOverrides()
        regions = []
        active = nil
        didRelease = false
        isHolding = false
        displayDwell = 0
    }

    // MARK: - The tick

    /// Advance the region state machine.
    ///
    /// Called from the engine's existing timing loop — NOT from a display link
    /// and NOT from a timer of its own. Everything below is O(regions), which
    /// is a handful, and nothing here walks the document, rebuilds a
    /// projection, or issues a media command unless a phase actually changed.
    public func tick() {
        guard !regions.isEmpty,
              let authored = authoredClock?(), let now = runtimeClock?() else { return }

        // ENTERING. Half-open containment, so a boundary belongs to whatever
        // follows and two adjacent regions cannot both claim an instant.
        if active == nil, let entering = StoryRegionTimeline.region(at: authored, in: regions) {
            active = StoryRegionRuntime(region: entering, enteredAtRuntimeTime: now)
            didRelease = false
            logger.info("Entered Explore region '\(entering.name ?? entering.id)' at \(String(format: "%.2f", authored))s")
        }

        guard var runtime = active else { return }

        // THE FALLBACK TIMER, polled rather than scheduled — measured from
        // region ENTRY, on the pause-aware clock.
        if runtime.applyFallbackIfDue(atRuntimeTime: now) {
            logger.info("Explore region '\(runtime.region.id)' resolved by its fallback timer")
        }

        let phase = runtime.phase(authoredTime: authored)

        // ENTERING THE HOLD: the authored first pass has reached the boundary
        // with the exit unresolved.
        if phase == .held, !isHolding {
            isHolding = true
            applyContinuations(for: runtime.region, phase: .enteringHold)
            holdDidBegin?(runtime.region)
            logger.info("Explore hold at \(String(format: "%.2f", authored))s — story parked")
        }

        // The loop overlay, for the few targets explicitly authored to loop.
        if isHolding, let sampleTime = runtime.loopSampleTime(authoredTime: authored, atRuntimeTime: now) {
            for entity in installedLoops {
                setAnimationLoopOverride?(entity, sampleTime)
            }
        }

        // RELEASING. The exit resolved (by condition or timer) while held, so
        // the story may go. One call, the same one a tap makes.
        if phase == .resolved || runtime.resolution != nil {
            if isHolding {
                leaveHold(runtime.region)
                logger.info("Explore region '\(runtime.region.id)' released — resuming Directed playback")
                releaseOnce()
            } else if Self.isEnd(of: runtime.region, at: authored) {
                // RESOLVED BEFORE THE HOLD BEGAN, and the story is now AT the
                // boundary. A fallback no longer than the preview (the
                // default) expires as the first pass ends, so the hold never
                // began, and this used to release nothing: the exit gate
                // waited for an act that was no longer asked for, forever.
                // There is no hold to leave, only the boundary to let go.
                // A no-op unless the engine is waiting there; when it is not,
                // the engine sees the resolved exit and does not wait.
                releaseOnce()
            }
            // Resolved during the FIRST PASS, short of the boundary: nothing
            // to release, and nothing to skip. Authored time simply runs to
            // the boundary and out.
        }

        // A DWELL READOUT AT ONE HERTZ, not per tick. It is a label whose text
        // width changes; publishing it at tick rate would invalidate its host
        // several times a second for a number that reads the same.
        if isHolding {
            let whole = Int(runtime.dwell(authoredTime: authored, atRuntimeTime: now))
            if whole != displayDwell { displayDwell = whole }
        }

        active = runtime
    }

    /// The viewer satisfied the exit — a tap, a facing dwell, an approach, a
    /// grab, or an accessible activation of the same interaction.
    ///
    /// Idempotent, and safe during the first pass: it marks the exit satisfied
    /// so the story does not stall when it reaches the boundary, WITHOUT
    /// skipping any authored content in between.
    public func resolveActiveRegion() {
        guard var runtime = active, let now = runtimeClock?() else { return }
        guard runtime.resolution == nil else { return }
        runtime.resolve(.exitCondition, atRuntimeTime: now)
        active = runtime
        logger.info("Explore exit satisfied for '\(runtime.region.id)'")
    }

    /// Playback left the region for a reason outside its own rules.
    public func interruptActiveRegion() {
        guard var runtime = active, let now = runtimeClock?() else { return }
        runtime.resolve(.interrupted, atRuntimeTime: now)
        active = runtime
        clearLoopOverrides()
        endHoldIfNeeded()
    }

    /// Drops the active region so the next one can be entered, whatever
    /// position playback is at. For a move that leaves the region without
    /// passing its exit (a seek, a Segment jump); the segment loop crossing a
    /// boundary uses `boundaryDidPass(at:)`, which completes a region only at
    /// its own end.
    public func regionDidComplete() {
        endHoldIfNeeded()
        clearLoopOverrides()
        active = nil
        didRelease = false
        displayDwell = 0
    }

    /// THE EXIT RELEASED THE HOLD: the viewer acted, a Memory exit came true,
    /// or the fallback let the story go, and the story is leaving the
    /// boundary now.
    ///
    /// Runs the leaving-hold continuations, the exit fade among them. They
    /// used to run only inside `tick`, on the path where the fallback timer
    /// resolved the region, so an author's exit fade played when the timer
    /// ran out and never when the viewer was the one who left. Idempotent:
    /// once the hold has ended there is nothing to leave.
    public func exitDidRelease() {
        guard isHolding, let runtime = active else { return }
        leaveHold(runtime.region)
        logger.info("Explore region '\(runtime.region.id)' exit released the hold")
    }

    /// The segment loop crossed the Segment boundary at `boundary` (authored
    /// Sequence time) and is moving on.
    ///
    /// COMPLETES A REGION ONLY AT ITS OWN END. A Segment break inside an
    /// Explore Area is not the Area's end, and dropping the region there
    /// re-entered it at the next tick with a fresh fallback timer and its
    /// resolution forgotten. A hold still on at the end was released by the
    /// exit, so it leaves through `exitDidRelease` first.
    public func boundaryDidPass(at boundary: TimeInterval) {
        guard let runtime = active,
              runtime.region.endTime <= boundary + Self.boundaryTolerance else { return }
        exitDidRelease()
        regionDidComplete()
    }

    /// Is the story currently parked in an Explore hold? The engine asks before
    /// letting a boundary gate go.
    public var isHoldingStory: Bool { isHolding }

    /// DOES A STORY REGION OWN THE TIMING OF THE GATE NOW WAITING?
    ///
    /// A region has ONE fallback timer, measured from region entry. The gate
    /// compiled onto its boundary may still carry a `timeout` in a document
    /// authored before that was normalized — and a gate timeout measures from
    /// the moment it starts waiting, so the two would race and the shorter one
    /// would silently win.
    ///
    /// Read while a gate waits, when the authored clock is parked at that
    /// gate's boundary. See `ownsGateTiming(atBoundary:)`.
    public var ownsActiveGateTiming: Bool {
        guard let authored = authoredClock?() else { return false }
        return ownsGateTiming(atBoundary: authored)
    }

    /// True only for the gate at the active region's END, because that gate
    /// IS the region's exit. A gate on a Segment break inside the Area is an
    /// ordinary Cue and keeps its own timeout.
    public func ownsGateTiming(atBoundary boundary: TimeInterval) -> Bool {
        guard let runtime = active else { return false }
        return Self.isEnd(of: runtime.region, at: boundary)
    }

    /// Has the exit of the region ending at `boundary` already resolved? Then
    /// the story does not stall there: a region resolved during its first
    /// pass plays to its end and out (`StoryRegionRuntime` rule 2).
    public func exitAlreadyResolved(atBoundary boundary: TimeInterval) -> Bool {
        guard let runtime = active, runtime.resolution != nil else { return false }
        return Self.isEnd(of: runtime.region, at: boundary)
    }

    /// How close a Segment boundary must be to a region's end to BE that end.
    /// The compiled break sits on the region's end to within 1e-4 s
    /// (`StoryRegionEditing`), and the engine sums Segment durations to find
    /// it, so exact equality is not a test either side can promise.
    static let boundaryTolerance: TimeInterval = 1e-3

    static func isEnd(of region: StoryRegion, at time: TimeInterval) -> Bool {
        abs(region.endTime - time) <= boundaryTolerance
    }

    // MARK: - Continuations

    private func applyContinuations(for region: StoryRegion, phase: ContinuationPhase) {
        for continuation in region.continuations {
            // AN EXIT FADE IS INDEPENDENT OF THE BEHAVIOR, so it is handled
            // before the `.hold` early-out: content left on its default can
            // still be authored to fade as the story resumes.
            if phase == .leavingHold, let seconds = continuation.exitFade, seconds > 0 {
                applyExitFade?(continuation.target, seconds)
            }

            // FOR AN ANIMATION, `.hold` means "do nothing": its only clock is
            // the authored one, and that is already parked.
            //
            // FOR MEDIA IT DOES NOT. A video or a sound runs on its own
            // player, which a parked Sequence clock does not stop — so an
            // explicit hold has to reach the host and pause something. This
            // guard used to skip `.hold` for every target, which made the
            // host's pause unreachable: "Hold Last Frame" kept playing on
            // device.
            if case .entityAnimation = continuation.target,
               continuation.behavior == .hold { continue }

            if case .entityAnimation(let entity) = continuation.target,
               continuation.behavior == .loop {
                switch phase {
                case .enteringHold: installedLoops.insert(entity)
                case .leavingHold:  installedLoops.remove(entity)
                }
            }
            applyContinuation?(continuation.target, continuation.behavior, phase)
        }
    }

    /// The exit released the hold: the leaving-hold continuations, then the
    /// hold ends. Said once for the timer's release in `tick` and for every
    /// other exit in `exitDidRelease`.
    private func leaveHold(_ region: StoryRegion) {
        applyContinuations(for: region, phase: .leavingHold)
        clearLoopOverrides()
        endHoldIfNeeded()
        displayDwell = 0
    }

    /// Let the story go, once per region execution. The same call a tap
    /// makes (`SequenceEngine.satisfyGate`).
    private func releaseOnce() {
        guard !didRelease else { return }
        didRelease = true
        releaseStory?()
    }

    /// Leave the held state, telling the host exactly once.
    private func endHoldIfNeeded() {
        guard isHolding else { return }
        isHolding = false
        holdDidEnd?()
    }

    /// Remove every animation loop overlay, returning those entities to
    /// ordinary Sequence evaluation.
    private func clearLoopOverrides() {
        for entity in installedLoops { setAnimationLoopOverride?(entity, nil) }
        installedLoops.removeAll()
    }
}
