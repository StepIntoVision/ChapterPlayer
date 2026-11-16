//
//  InteractionController.swift
//  ChapterPlayer
//
//  RUNNING AUTHORED INTERACTIONS ON DEVICE.
//
//  An `InteractionSpec` says: when the viewer does X to this object, run these
//  actions, this often. This turns that into live detection, dispatch and
//  affordances — and then takes it all down again when the Sequence changes.
//
//  FOUR RULES SHAPE EVERYTHING HERE.
//
//  1. RESPONSES GO THROUGH THE EXISTING ENGINE. `perform` hands the actions to
//     `SequenceEngine`, which routes them to the same executors a segment's
//     actions use. There is no `playAudioFromInteraction`. An interaction
//     decides WHEN a behavior runs and never what it means.
//
//  2. DETECTION IS SHARED WITH GATES (`SpatialTriggerDetector`). One cone, one
//     dwell, one proximity poll, one manipulation subscription.
//
//  3. FEEDBACK IS NOT A TRIGGER. The hover affordance says "this can be
//     interacted with". It never fires the `.look` interaction, and the
//     `.look` interaction never changes what the object looks like. Keeping
//     them apart is what stops "it lit up" from meaning "it happened".
//
//  4. NOTHING LEAKS. Every watch, every subscription and every spent-once
//     record is owned here and released in `teardown()`, which the engine calls
//     on every sequence transition. A watch that outlives its Sequence is a
//     tap on a door in Act One firing narration in Act Three.
//
//  5. ACCESSIBILITY IS A ROUTE, NOT A SECOND ENGINE. A VoiceOver activation and
//     a physical tap arrive at the same `fire(_:)`, obey the same ledger, and
//     run the same responses. There is no `voiceOverResponse()`.
//
//  A SEQUENCE VISIT is one runtime execution instance of a Sequence, from entry
//  until it exits, completes, stops or is discarded. `install` begins one;
//  `teardown` ends it. All transient state — effective enablement, spent
//  one-shots, dwell progress, trigger edges — belongs to the visit and is never
//  serialized.
//
//  MAESTRO DOES NOT KNOW WHERE THE VIEWER IS LOOKING. `.viewerFacing` is the
//  device's forward direction. SYSTEM-EYE-INPUT: the platform's own hover effect
//  responds to real eye input privately, outside this process, and that signal
//  never arrives here. The two may disagree. Do not "fix" that.
//
//  WHAT THIS DELIBERATELY DOES NOT DO: gates. Nothing here reads, writes or
//  satisfies a `SegmentGate`. An interaction leaves the story exactly where it was.
//

import Combine
import Foundation
import OSLog
import RealityKit
import ChapterScript
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "Interactions"
)

@MainActor
@Observable
public final class InteractionController {

    // MARK: - Wiring

    /// Shared with `GateDetectionController` — see `SpatialTriggerDetector`.
    @ObservationIgnored public let detector: SpatialTriggerDetector

    /// Runs a response. Wired to `SequenceEngine.performActions`, so an
    /// interaction's actions travel the same path a segment's do.
    @ObservationIgnored public var perform: (([SegmentAction]) -> Void)?

    /// Resolves an authored entity name to the live entity.
    @ObservationIgnored public var entityProvider: ((String) -> Entity?)?
    /// Resolves an already-stored typed USD part target. It never discovers or
    /// mints paths; an unresolved/ambiguous path stays unresolved.
    @ObservationIgnored public var subElementProvider: ((SubElementTarget) -> Entity?)?

    /// The document currently loaded. Supplied as a closure so `reinstall()`
    /// can re-arm from inside the engine's play path — which is the ONE place
    /// guaranteed to run on every route into a Sequence (play, playAndAwait,
    /// restart, auto-advance). A host that installed by hand at each call site
    /// would eventually miss one, and a missed one is a chapter where nothing
    /// is interactive with no error anywhere.
    @ObservationIgnored public var documentProvider: (() -> ChapterDocument?)?

    /// THE SEQUENCE THAT IS PLAYING, read by `reinstall()` (format 8, OD-21).
    ///
    /// An Object's Interactions belong to each use of it in a Sequence, so a
    /// visit arms the playing Sequence's Interactions and no other's. The
    /// host wires this to the engine's current Sequence
    /// (`sequenceEngine.currentSequence?.id`), which `play` sets before it
    /// calls `reinstall()`. Left unwired it answers nil, and `install` falls
    /// back to arming every Sequence's Interactions once each (the
    /// pre-format-8 behavior), so a host that has not wired it yet still
    /// answers every tap it answered before.
    @ObservationIgnored public var playingSequenceProvider: (() -> String?)?

    /// The Sequence the current visit armed (nil: every Sequence, see above).
    public private(set) var armedSequenceId: String?

    /// Fired after any interaction runs — id and entity. Hosts use it for
    /// debug overlays and for the Mac preview's "this one fired" readout.
    @ObservationIgnored public var onInteractionFired: ((_ entityId: String, _ interactionId: String) -> Void)?

    /// THE OTHER CONSUMER OF A SEMANTIC ACTIVATION.
    ///
    /// One viewer action can mean two things at once: an object's own behavior
    /// (an Interaction) and permission for the story to continue (a Gate). They
    /// are different consumers with different rules, and this is how the second
    /// one hears about the activation without the first one knowing it exists.
    ///
    /// Returns true when a gate was satisfied. Wired by `ChapterPlayerCore` to
    /// the engine; nil in tests, where only the interaction half is exercised.
    /// `isAccessible` is carried for logging and QA only — it must never change
    /// the outcome, which is the whole point of accessibility being a ROUTE.
    @ObservationIgnored public var offerToGate:
        ((_ entityName: String?, _ trigger: InteractionTrigger,
          _ interactionRan: Bool, _ isAccessible: Bool) -> Bool)?

    // MARK: - Observable state

    /// 0…1 dwell progress per entity for `.viewerFacing` interactions, so a
    /// host can draw a patience ring. Written only on CHANGE.
    public private(set) var facingProgress: [String: Double] = [:]

    /// How many interactions are currently armed. Diagnostic; also what a host
    /// shows when the author asks "is anything interactive right now?".
    public private(set) var armedCount: Int = 0

    // MARK: - Internal state

    private struct Registration {
        let entityId: String
        let target: SubElementTarget?
        var watch: SpatialTriggerDetector.Watch?
    }

    /// WHETHER an interaction may fire lives in the shared ledger
    /// (`ChapterScript.InteractionLedger`) — lifetime, enablement and the
    /// spent-once record are arithmetic, and the Mac's preview asks the same
    /// object. What stays here is the RealityKit half: which watch is running
    /// and which entity it belongs to.
    private var ledger = InteractionLedger()
    /// Watches keyed by interaction id. One flat table: an id is globally
    /// unique, which is what makes `enableInteraction` a lookup, not a search.
    private var registrations: [String: Registration] = [:]
    /// Order preserved for deterministic tap resolution when two interactions
    /// on one object share a trigger.
    private var order: [String] = []
    /// Entities whose interactivity affordances this controller installed, so
    /// teardown removes exactly what it added and nothing an author authored.
    private var decorated: [String: DecorationRecord] = [:]

    private struct DecorationRecord {
        var ownerId: String
        var target: SubElementTarget?
        var addedInputTarget: Bool
        var addedCollision: Bool
        var addedHoverEffect: Bool
        var addedAccessibility: Bool
        /// The AUTHORED style, kept so a mid-experience accessibility change
        /// can recompute the effect without needing the document again — and
        /// so recomputing can never silently reset a chosen style to automatic.
        var feedback: InteractionFeedbackSpec
    }

    #if canImport(UIKit)
    private var accessibilityObservers: [NSObjectProtocol] = []
    #endif
    /// Scene subscriptions for accessibility activation. Owned by the visit and
    /// released in `teardown()` like every other subscription here.
    private var accessibilitySubscriptions: [any Cancellable] = []

    public init(detector: SpatialTriggerDetector = SpatialTriggerDetector()) {
        self.detector = detector
        observeAccessibilitySettings()
    }

    // MARK: - Install / teardown

    /// Arm the PLAYING Sequence's Interactions (`playingSequenceProvider`).
    ///
    /// Called at Sequence start. Since format 8 an Interaction belongs to one
    /// use of an Object in one Sequence (OD-21), so Act Three never answers a
    /// tap Act One authored. An armed Object that is not on screen is still
    /// never hit: the watches all check `entity.scene != nil` and
    /// `isEnabledInHierarchy` first.
    public func install(document: ChapterDocument) {
        install(document: document, sequenceId: playingSequenceProvider?())
    }

    /// Arm `sequenceId`'s Interactions; nil arms every Sequence's once each
    /// (`armedInteractions(in:sequenceId:)`).
    public func install(document: ChapterDocument, sequenceId: String?) {
        teardown()
        armedSequenceId = sequenceId
        var definitions: [String: EntityDefinition] = [:]
        for entity in document.entities where definitions[entity.id] == nil {
            definitions[entity.id] = entity
        }
        for use in Self.armedInteractions(in: document, sequenceId: sequenceId) {
            // An Object with no definition has nothing to decorate or resolve.
            guard let entity = definitions[use.objectId] else { continue }
            ledger.register(use.interactions)
            // Feedback belongs to this use of the Object (format 9, OD-128).
            let feedback = Self.armedFeedback(forObject: entity.id, in: document,
                                              sequenceId: sequenceId)
            for spec in use.interactions {
                decorate(entity, interactions: use.interactions, target: spec.target,
                         feedback: feedback)
                register(spec, on: entity.id)
            }
        }
        armedCount = ledger.armedCount
        // One subscription per visit, on whatever scene the entities landed in.
        if let scene = decorated.keys.compactMap({ entityProvider?($0)?.scene }).first {
            subscribeAccessibility(in: scene)
        }
        logger.info("Armed \(self.armedCount) interaction(s) across \(self.decorated.count) object(s) for Sequence '\(sequenceId ?? "every Sequence")'")
    }

    /// WHAT ONE VISIT ARMS. Pure, so it is the same answer on every host.
    ///
    /// With a Sequence: that Sequence's Interactions in the Chapter's Object
    /// order (`ChapterDocument.interactions(inSequence:)`, which also places a
    /// pre-format-8 list the document has not lifted yet).
    ///
    /// Without one (a host that has not wired `playingSequenceProvider`):
    /// every Sequence's Interactions, an id armed once (its first use wins,
    /// since the ledger is keyed by id), then any pre-format-8 list still on
    /// an Object. That is what was armed before format 8.
    public static func armedInteractions(in document: ChapterDocument,
                                         sequenceId: String?) -> [ObjectInteractions] {
        if let sequenceId { return document.interactions(inSequence: sequenceId) }
        var seen: Set<String> = []
        var merged: [ObjectInteractions] = []
        var indexByObject: [String: Int] = [:]
        for use in document.allObjectInteractions {
            let fresh = use.interactions.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            if let index = indexByObject[use.objectId] {
                merged[index].interactions += fresh
            } else {
                indexByObject[use.objectId] = merged.count
                merged.append(ObjectInteractions(sequenceId: nil, objectId: use.objectId,
                                                 interactions: fresh))
            }
        }
        return merged
    }

    /// THE FEEDBACK ONE VISIT SHOWS FOR AN OBJECT (format 9, OD-128). Pure,
    /// so it is the same answer on every host.
    ///
    /// With a Sequence: that Sequence's own Feedback for the Object, falling
    /// back to a pre-format-9 Object-level value an unmigrated document still
    /// carries, else Automatic. Without one (a host that has not wired
    /// `playingSequenceProvider`): the first Sequence that sets one, else the
    /// Object-level value. `ChapterDocument.interactionFeedback(onObject:inSequence:)`.
    public static func armedFeedback(forObject objectId: String,
                                     in document: ChapterDocument,
                                     sequenceId: String?) -> InteractionFeedbackSpec {
        document.interactionFeedback(onObject: objectId, inSequence: sequenceId)
    }

    /// Re-arm from `documentProvider`, for the playing Sequence. No-op when no
    /// document is loaded.
    public func reinstall() {
        guard let document = documentProvider?() else { return }
        install(document: document, sequenceId: playingSequenceProvider?())
    }

    /// **THIS VISIT'S ONE-SHOT AND ENABLEMENT STATE, TO PUT ASIDE.**
    ///
    /// `.once` is per Sequence Visit, and every entry into a Sequence re-arms
    /// (`play` -> `reinstall`). That is right for a fresh visit and wrong for a
    /// RESUMED one: Return · Resume continues the visit the audience left, so
    /// what they had already spent must still be spent. The navigator preserved
    /// the visit id for exactly this and nothing downstream consumed it, so the
    /// documented difference between the two Return policies did not exist at
    /// runtime.
    ///
    /// The host holds these per visit id and hands one back on a resume. Pure
    /// authored-value arithmetic, never serialized.
    public var ledgerSnapshot: InteractionLedger { ledger }

    /// Put a suspended visit's state back, after `install` has re-registered
    /// the same Sequence's interactions. Same Sequence, same objects, same ids.
    public func restoreLedger(_ restored: InteractionLedger) {
        ledger = restored
        // The detector's span watches have just started closed. A span left
        // open by the suspended visit is closed too (nothing is undone: the
        // visit's scene was rebuilt), so the first real span after the resume
        // begins normally and its end has something to undo.
        ledger.closeAllSpansWithoutRelease()
    }

    /// Release everything. Idempotent, and called on every sequence
    /// transition — a watch that survives one is the leak this method exists
    /// to make impossible.
    public func teardown() {
        accessibilitySubscriptions.forEach { $0.cancel() }
        accessibilitySubscriptions = []
        for registration in registrations.values { registration.watch?.cancel() }
        registrations.removeAll()
        order.removeAll()
        // `reset`, not `rearm`: a teardown is the end of a RUN, so a `.once`
        // interaction is armed again next time the Sequence plays.
        ledger.reset()
        facingProgress.removeAll()
        armedCount = 0
        for (_, record) in decorated {
            guard let entity = record.target.flatMap({ subElementProvider?($0) })
                    ?? entityProvider?(record.ownerId)
            else { continue }
            undecorate(entity, record: record)
        }
        decorated.removeAll()
        gateTargetNames = []
        areaTargetNames = []
        applyCueTargets()
    }

    // MARK: - Objects a Cue or a Choice is waiting for (OD-150)

    /// AN OBJECT THE STORY ASKS YOU TO TAP CAN BE TAPPED, AND SHOWS IT.
    ///
    /// Only Objects with Interactions were given a hit shape, an
    /// `InputTargetComponent` and the system hover effect, so the Objects a Cue
    /// or a Choice names ("Tap the lantern", a relic to choose, the lighthouse
    /// that takes you home, a stair) had none on the headset: no system highlight on
    /// hover and nothing for the tap to land on. The Mac preview
    /// clicks through its own hit test, which is why it never showed there.
    ///
    /// While a Cue listens (waiting, or from its Segment's start, OD-149), its
    /// Object and its Choice options' Objects get the same affordances an
    /// Interaction gets, and an Explore Area's exit Object gets them from Area
    /// entry. Only what this added is removed when they stop listening.
    private var gateTargetNames: Set<String> = []
    private var areaTargetNames: Set<String> = []
    private var cueTargetRecords: [String: CueTargetRecord] = [:]

    private struct CueTargetRecord {
        var addedCollision: Bool
        var addedInputTarget: Bool
        var addedHoverEffect: Bool
        var addedAccessibility: Bool
    }

    /// The Objects the listening Cue names (its own, and its Choice options').
    public func setGateTargets(_ names: Set<String>, label: String?) {
        cueTargetRetries = 0
        gateTargetNames = names.filter { !$0.isEmpty }
        cueTargetLabel = label
        applyCueTargets()
    }

    private var cueTargetLabel: String?

    /// TEST SEAM: the Objects currently decorated as Cue targets.
    public var cueTargetNamesForTesting: Set<String> { Set(cueTargetRecords.keys) }

    private func applyCueTargets() {
        let wanted = gateTargetNames.union(areaTargetNames)
        for name in cueTargetRecords.keys where !wanted.contains(name) {
            guard let record = cueTargetRecords.removeValue(forKey: name),
                  let entity = entityProvider?(name) else { continue }
            if record.addedCollision { entity.components.remove(CollisionComponent.self) }
            if record.addedInputTarget { entity.components.remove(InputTargetComponent.self) }
            if record.addedHoverEffect { entity.components.remove(HoverEffectComponent.self) }
            if record.addedAccessibility { entity.components.remove(AccessibilityComponent.self) }
        }
        for name in wanted where cueTargetRecords[name] == nil {
            guard let entity = entityProvider?(name) else { continue }
            var record = CueTargetRecord(addedCollision: false, addedInputTarget: false,
                                         addedHoverEffect: false, addedAccessibility: false)
            if entity.components[CollisionComponent.self] == nil {
                let bounds = entity.visualBounds(relativeTo: entity)
                let usable = simd_length(bounds.extents) > 0.001
                entity.components.set(CollisionComponent(shapes: [
                    usable ? .generateBox(size: bounds.extents).offsetBy(translation: bounds.center)
                           : .generateSphere(radius: 0.1)
                ]))
                record.addedCollision = true
            }
            if entity.components[InputTargetComponent.self] == nil {
                entity.components.set(InputTargetComponent())
                record.addedInputTarget = true
            }
            if entity.components[HoverEffectComponent.self] == nil,
               let effect = hoverEffect(for: InteractionFeedbackSpec()) {
                entity.components.set(effect)
                record.addedHoverEffect = true
            }
            if entity.components[AccessibilityComponent.self] == nil {
                var accessibility = AccessibilityComponent()
                accessibility.isAccessibilityElement = true
                accessibility.label = LocalizedStringResource(stringLiteral: name)
                if let label = cueTargetLabel, !label.isEmpty {
                    accessibility.value = LocalizedStringResource(stringLiteral: label)
                }
                accessibility.systemActions = [.activate]
                entity.components.set(accessibility)
                record.addedAccessibility = true
            }
            cueTargetRecords[name] = record
            // Activation reaches `handleTap` through the scene subscription; a
            // Sequence with no Interactions never subscribed.
            if accessibilitySubscriptions.isEmpty, let scene = entity.scene {
                subscribeAccessibility(in: scene)
            }
        }
        // An Object revealed in the same moment the Cue starts listening may not
        // be in the scene yet: look again shortly, while it is still wanted.
        cueTargetRetry?.cancel()
        cueTargetRetry = nil
        let missing = wanted.subtracting(cueTargetRecords.keys)
        if !missing.isEmpty, cueTargetRetries < 40 {
            cueTargetRetries += 1
            cueTargetRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.applyCueTargets()
            }
        } else if missing.isEmpty {
            cueTargetRetries = 0
        }
    }

    private var cueTargetRetry: Task<Void, Never>?
    private var cueTargetRetries = 0

    // MARK: - Registration

    private func register(_ spec: InteractionSpec, on entityId: String) {
        registrations[spec.id] = Registration(entityId: entityId,
                                               target: spec.target, watch: nil)
        order.append(spec.id)
        startWatch(for: spec.id)
    }

    /// Start (or restart) the detection for one registration.
    ///
    /// `.tap` starts nothing: a tap arrives from the host's gesture through
    /// `handleTap`, because the gesture belongs to the SwiftUI `RealityView`
    /// and cannot be subscribed to from here.
    private func startWatch(for interactionId: String) {
        guard var registration = registrations[interactionId],
              let spec = ledger.spec(interactionId) else { return }
        registration.watch?.cancel()
        registration.watch = nil

        let repeats = spec.lifetime == .everyTime
        let entityId = registration.entityId
        let resolver: @MainActor () -> Entity? = { [weak self] in
            self?.resolvedEntity(for: interactionId)
        }

        // A SPAN TIMING on a lasting trigger watches both edges (OD-49). On a
        // tap there is no span, and the tap route below treats it as
        // `.everyTime`.
        if spec.lifetime.isSpanTiming, spec.trigger.hasSpan {
            registration.watch = startSpanWatch(for: interactionId, spec: spec,
                                                entityId: entityId, resolver: resolver)
            registrations[interactionId] = registration
            return
        }

        switch spec.trigger {
        case .tap:
            break
        case .viewerFacing(let dwell):
            registration.watch = detector.watchViewerFacing(
                target: entityId, entityResolver: resolver,
                dwell: dwell, repeats: repeats,
                progress: { [weak self] progress in
                    guard let self, self.facingProgress[entityId] != progress else { return }
                    self.facingProgress[entityId] = progress
                },
                onTriggered: { [weak self] in self?.activate(interactionId) }
            )
        case .approach(let radius):
            registration.watch = detector.watchProximity(
                // `.baseline`: an interaction fires on the ENTRY EDGE. Arming
                // while the viewer already stands inside the radius — a
                // Sequence starting, an object being revealed, an interaction
                // being enabled — is not an approach, and firing there would
                // start narration at somebody who has not moved.
                target: entityId, entityResolver: resolver,
                radius: radius, repeats: repeats, arming: .baseline,
                onTriggered: { [weak self] in self?.activate(interactionId) }
            )
        case .grab:
            registration.watch = detector.watchGrab(
                target: entityId, entityResolver: resolver, repeats: repeats,
                onTriggered: { [weak self] in self?.activate(interactionId) }
            )
        }
        registrations[interactionId] = registration
    }

    /// The two-edge watch behind `.whileActive`, `.onEnter` and `.onExit`.
    private func startSpanWatch(
        for interactionId: String, spec: InteractionSpec, entityId: String,
        resolver: @escaping @MainActor () -> Entity?
    ) -> SpatialTriggerDetector.Watch? {
        let onBegin: @MainActor () -> Void = { [weak self] in self?.beginSpan(interactionId) }
        let onEnd: @MainActor () -> Void = { [weak self] in self?.endSpan(interactionId) }
        switch spec.trigger {
        case .tap:
            return nil
        case .viewerFacing(let dwell):
            return detector.watchViewerFacingSpan(
                target: entityId, entityResolver: resolver, dwell: dwell,
                progress: { [weak self] progress in
                    guard let self, self.facingProgress[entityId] != progress else { return }
                    self.facingProgress[entityId] = progress
                },
                onBegin: onBegin, onEnd: onEnd)
        case .approach(let radius):
            return detector.watchProximitySpan(
                target: entityId, entityResolver: resolver, radius: radius,
                onBegin: onBegin, onEnd: onEnd)
        case .grab:
            return detector.watchGrabSpan(
                target: entityId, entityResolver: resolver,
                onBegin: onBegin, onEnd: onEnd)
        }
    }

    // MARK: - Spans (OD-49)

    /// A lasting trigger's condition became true. The ledger decides what
    /// runs (`InteractionLedger.beginSpan`); presence is the detector's
    /// half, which only begins a span on a present Object.
    @discardableResult
    public func beginSpan(_ interactionId: String) -> Bool {
        guard let registration = registrations[interactionId] else { return false }
        guard isPresent(registration) else { return false }
        // RECORD BEFORE ANYTHING RUNS (TODO-104): whether each Object the
        // responses show or hide is visible now, so the span's end puts it
        // back rather than applying the opposite.
        let recorded = visibilityNow(of: ledger.spec(interactionId)?.actions ?? [])
        let (outcome, responses) = ledger.beginSpan(interactionId, visibility: { recorded[$0] })
        guard outcome.didFire else {
            logger.debug("Interaction '\(interactionId)' span begin refused: \(String(describing: outcome))")
            return false
        }
        armedCount = ledger.armedCount
        guard !responses.isEmpty else { return false }
        beginningSpans.insert(interactionId)
        dispatch(responses, interactionId: interactionId, entityId: registration.entityId)
        beginningSpans.remove(interactionId)
        // A RESPONSE THAT REMOVED ITS OWN PRESENCE (hid its Object, turned
        // itself off) ended the span itself. Closed without undoing: undoing
        // would show the Object again with the viewer still there, and the
        // span would begin again on the next tick, for as long as they stay.
        if ledger.isSpanOpen(interactionId),
           !isPresent(registration) || !ledger.isEffectivelyEnabled(interactionId) {
            logger.info("Interaction '\(interactionId)' span ended by its own response; nothing is undone")
            ledger.closeSpanWithoutRelease(interactionId)
        }
        return true
    }

    /// Whether each Object `actions` show, hide or reveal is visible right now
    /// (`isEnabled`, what show and hide write). An Object not in the registry
    /// has no entry, and its end falls back to the opposite.
    private func visibilityNow(of actions: [SegmentActionDTO]) -> [String: Bool] {
        var visible: [String: Bool] = [:]
        for name in InteractionSpanRelease.visibilityTargets(of: actions) {
            if let entity = entityProvider?(name) { visible[name] = entity.isEnabled }
        }
        return visible
    }

    /// THE ACCESSIBLE ROUTE TO ONE INTERACTION (TODO-104).
    ///
    /// For a span timing on a lasting trigger the accessible action is a
    /// toggle, the rule `InteractionLedger.toggleSpan` states: `.whileActive`
    /// and `.onExit` begin the span on one activation and end it on the next;
    /// everything else, `.onEnter` included, is an ordinary activation. It goes
    /// through `beginSpan` / `endSpan`, so presence, the recorded visibility
    /// and a response that ends its own span behave exactly as on the
    /// physical route. Returns whether a response ran.
    @discardableResult
    public func activateAccessibly(_ interactionId: String) -> Bool {
        guard let spec = ledger.spec(interactionId) else { return false }
        guard spec.trigger.hasSpan else { return activate(interactionId) }
        switch spec.lifetime {
        case .whileActive, .onExit:
            return ledger.isSpanOpen(interactionId) ? endSpan(interactionId) : beginSpan(interactionId)
        case .once, .everyTime, .onEnter:
            return activate(interactionId)
        }
    }

    /// Interactions whose span-begin responses are running right now. Read
    /// by `setInteraction` so a response that turns its own interaction off
    /// closes the span instead of undoing what it has just done.
    private var beginningSpans: Set<String> = []

    /// A lasting trigger's condition stopped being true, including because
    /// the Object was hidden or left the scene. Presence is NOT required:
    /// the Object going away is itself an end.
    @discardableResult
    public func endSpan(_ interactionId: String) -> Bool {
        guard let registration = registrations[interactionId] else { return false }
        let (outcome, responses) = ledger.endSpan(interactionId)
        guard outcome.didFire, !responses.isEmpty else { return false }
        dispatch(responses, interactionId: interactionId, entityId: registration.entityId)
        return true
    }

    /// Run a response through the ONE engine path and report it.
    private func dispatch(_ responses: [SegmentActionDTO], interactionId: String, entityId: String) {
        let actions = responses.compactMap { dto -> SegmentAction? in
            do { return try SegmentAction(dto: dto) } catch {
                logger.warning("Interaction '\(interactionId)' carries an action this build cannot run: \(String(describing: error))")
                return nil
            }
        }
        logger.info("Interaction '\(interactionId)' on '\(entityId)' → \(actions.count) action(s)")
        perform?(actions)
        onInteractionFired?(entityId, interactionId)
    }

    // MARK: - Firing

    /// The one place an interaction becomes a response.
    ///
    /// `@discardableResult` returns whether anything ran, which is what the
    /// Mac's preview and the tests assert on — "the tap was received" and "the
    /// response executed" are different facts and a one-shot interaction makes
    /// them differ on the second tap.
    /// A detector or an input route says this interaction just activated.
    ///
    /// THE ELIGIBILITY GATE. `fire` is the ledger question ("may this respond?");
    /// this is the scene question ("is the object actually there?"). They are
    /// separate because the ledger is pure and knows nothing about a scene.
    @discardableResult
    public func activate(_ interactionId: String) -> Bool {
        guard let registration = registrations[interactionId] else { return false }
        guard isPresent(registration) else {
            logger.debug("Interaction '\(interactionId)' ignored: '\(registration.entityId)' is not present")
            return false
        }
        return fire(interactionId)
    }

    /// Can the viewer act on this object right now?
    ///
    /// An authored object that has not been revealed, has been hidden, or has
    /// left the scene must not satisfy ANY trigger — a stale collider is not
    /// presence. Deliberately the SAME question for all four triggers: before
    /// this, facing checked enablement, proximity checked only scene
    /// membership, and tap checked nothing at all, so a hidden object was
    /// tappable.
    ///
    /// Opacity is NOT consulted. A fade to zero is a rendering state, and this
    /// build's presence model is `isEnabledInHierarchy`; equating "invisible"
    /// with "gone" would silently change what a fade means.
    private func isPresent(_ registration: Registration) -> Bool {
        guard let entity = resolvedEntity(registration) else { return false }
        return entity.scene != nil && entity.isEnabledInHierarchy
    }

    private func resolvedEntity(for interactionId: String) -> Entity? {
        registrations[interactionId].flatMap(resolvedEntity)
    }

    private func resolvedEntity(_ registration: Registration) -> Entity? {
        if let target = registration.target {
            return subElementProvider?(target)
        }
        return entityProvider?(registration.entityId)
    }

    @discardableResult
    public func fire(_ interactionId: String) -> Bool {
        guard let registration = registrations[interactionId] else { return false }
        // ONE call decides and records. A separate check-then-commit is how
        // `.once` quietly becomes `.everyTime`.
        let (outcome, responses) = ledger.firing(interactionId)
        guard outcome.didFire else {
            logger.debug("Interaction '\(interactionId)' refused: \(String(describing: outcome))")
            return false
        }
        if ledger.spec(interactionId)?.lifetime == .once {
            // A one-shot's watch has nothing left to detect. Cancelling it
            // stops a proximity poll running for the rest of the Sequence for
            // a response that can never happen again.
            registrations[interactionId]?.watch?.cancel()
            registrations[interactionId]?.watch = nil
        }
        armedCount = ledger.armedCount
        dispatch(responses, interactionId: interactionId, entityId: registration.entityId)
        return true
    }

    /// A TAP HAPPENED. One semantic activation, offered to both consumers.
    ///
    /// Returns true when an interaction ran — the host still uses that to tell
    /// an interactive tap from an ordinary one.
    ///
    /// TWO CONSUMERS, EACH BY ITS OWN RULES:
    ///
    /// * the object's INTERACTIONS run (lifetime, enablement, presence);
    /// * an active GATE is offered the same activation, and decides for itself
    ///   whether it names this object.
    ///
    /// The Phase 6 rule is preserved exactly, and is now expressed where it
    /// belongs: a gate that names NO entity is still satisfied only by a tap
    /// that hit nothing interactive, so touching a prop cannot advance the
    /// film. A gate that DOES name this object is satisfied by tapping it —
    /// which is what "Continue when Tap Radio" says, and what an accessible
    /// activation of the same intent must also achieve.
    ///
    /// Resolution walks ancestry, because a tap on a USDZ subtree arrives on
    /// the mesh, not on the authored root.
    @discardableResult
    public func handleTap(on entity: Entity) -> Bool {
        var ancestry: [Entity] = []
        var node: Entity? = entity
        while let current = node { ancestry.append(current); node = current.parent }

        let candidates: [(id: String, depth: Int, owner: String)] = order.compactMap { id in
            guard let registration = registrations[id],
                  let spec = ledger.spec(id), case .tap = spec.trigger,
                  let target = resolvedEntity(registration),
                  let depth = ancestry.firstIndex(where: { $0 === target })
            else { return nil }
            return (id, depth, registration.entityId)
        }
        if let nearest = candidates.map(\.depth).min() {
            var ran = false
            var owner: String?
            for candidate in candidates where candidate.depth == nearest {
                owner = owner ?? candidate.owner
                if activate(candidate.id) { ran = true }
            }
            // A gate still targets an authored Object, not a prim path. The
            // interaction half resolves the exact part; the gate hears the
            // containing Object exactly once.
            _ = offerToGate?(owner, .tap, ran, false)
            return ran
        }
        // Nothing interactive under the pointer. The gate still hears it —
        // this is the legacy "tap anywhere targetable" path. It hears the
        // AUTHORED Object the tap landed in (OD-150): the nearest named node of
        // a USDZ is a mesh inside it ("Lantern_01"), which no Cue names.
        _ = offerToGate?(authoredName(of: ancestry) ?? resolvedName(of: entity), .tap, false, false)
        return false
    }

    /// The nearest ancestor that IS an authored Object (the entity the
    /// Chapter's registry holds under that name).
    private func authoredName(of ancestry: [Entity]) -> String? {
        ancestry.first { !$0.name.isEmpty && entityProvider?($0.name) === $0 }?.name
    }

    /// The nearest ancestor carrying an authored name, for gate targeting.
    private func resolvedName(of entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            if !current.name.isEmpty { return current.name }
            node = current.parent
        }
        return nil
    }

    /// Run every TAP interaction on one authored object, in authored order.
    /// The one implementation behind both a physical tap and an accessibility
    /// Activate.
    @discardableResult
    public func activateTaps(on entityId: String) -> Bool {
        var ran = false
        for id in order where registrations[id]?.entityId == entityId {
            guard let spec = ledger.spec(id), case .tap = spec.trigger else { continue }
            if activate(id) { ran = true }
        }
        return ran
    }

    /// Arm or disarm one authored interaction at runtime — the
    /// `enableInteraction` / `disableInteraction` actions.
    ///
    /// Disabling CANCELS the watch rather than filtering at fire time: a
    /// disabled proximity interaction should stop polling, not keep polling and
    /// throw the answer away.
    ///
    /// It changes RUNTIME state only. It does not touch `initiallyEnabled`, does
    /// not dirty the chapter, and does not clear a spent `.once` — re-enabling
    /// is not re-arming (`InteractionLedger.setEnabled`).
    public func setInteraction(_ interactionId: String, enabled: Bool) {
        guard ledger.spec(interactionId) != nil, registrations[interactionId] != nil else {
            logger.warning("No interaction '\(interactionId)' to \(enabled ? "enable" : "disable")")
            return
        }
        // Compares RUNTIME state, not the authored default — the two are
        // different questions and this one is "is it on right now".
        guard ledger.isEffectivelyEnabled(interactionId) != enabled else { return }
        ledger.setEnabled(enabled, id: interactionId)
        if enabled {
            startWatch(for: interactionId)
        } else {
            registrations[interactionId]?.watch?.cancel()
            registrations[interactionId]?.watch = nil
            // An open span ends with its watch: a `.whileActive` response is
            // undone rather than left on, and an `.onExit` that is now off
            // just closes (the ledger refuses it).
            if ledger.isSpanOpen(interactionId) {
                if beginningSpans.contains(interactionId) {
                    ledger.closeSpanWithoutRelease(interactionId)
                } else {
                    endSpan(interactionId)
                }
            }
        }
        armedCount = ledger.armedCount
    }

    /// Arm or disarm by (entity, interaction) — the shape the `enableInteraction`
    /// action carries. The entity is CHECKED rather than ignored: an id that
    /// exists on a different object means the document changed under the
    /// action, and firing it anyway would arm something the author did not name.
    public func setInteraction(_ interactionId: String, on entityId: String, enabled: Bool) {
        guard let registration = registrations[interactionId] else {
            logger.warning("No interaction '\(interactionId)' on '\(entityId)' to \(enabled ? "enable" : "disable")")
            return
        }
        guard registration.entityId == entityId else {
            logger.warning("Interaction '\(interactionId)' belongs to '\(registration.entityId)', not '\(entityId)' — ignoring")
            return
        }
        setInteraction(interactionId, enabled: enabled)
    }

    /// Every interaction currently registered on an entity, in authored order.
    /// Used by `enableInteraction`-by-entity and by hosts describing state.
    public func interactions(on entityId: String) -> [InteractionSpec] {
        order.filter { registrations[$0]?.entityId == entityId }
            .compactMap { ledger.spec($0) }
    }

    // MARK: - Accessibility as an input route

    /// THE NAME AN ASSISTIVE-TECHNOLOGY USER HEARS AND CHOOSES.
    ///
    /// It must describe the OUTCOME, not the physical act: a person who cannot
    /// walk up to a plinth is not helped by an action called "Approach". So the
    /// custom action is named from the authored response ("Play Recording"), or
    /// from the author's own hint when they wrote one.
    ///
    /// It is deliberately NOT the entity id, the filename, the channel or the
    /// interaction id — those are implementation strings, and speaking one is a
    /// defect, not a fallback.
    static func customActionName(for interaction: InteractionSpec) -> String {
        if let authored = interaction.accessibilityHint, !authored.isEmpty { return authored }
        if let authored = interaction.name, !authored.isEmpty { return authored }
        if let first = interaction.actions.first {
            return InteractionSemantics.responsePhrase(first)
        }
        // Nothing meaningful to say. The caller warns rather than speaking an
        // opaque name; see `accessibilityWarnings`.
        return InteractionSemantics.triggerPhrase(interaction.trigger)
    }

    /// Interactions whose accessible action cannot be described from authored
    /// data — an author-facing problem, surfaced rather than papered over with
    /// an implementation string.
    ///
    /// Every use in every Sequence is checked; an Interaction copied into
    /// several Sequences with the same content is reported once.
    public func accessibilityWarnings(in document: ChapterDocument) -> [String] {
        var names: [String: String] = [:]
        for entity in document.entities where names[entity.id] == nil {
            names[entity.id] = entity.resolvedDisplayName
        }
        var reported: Set<String> = []
        return document.allObjectInteractions.flatMap { use in
            use.interactions.compactMap { interaction -> String? in
                guard interaction.initiallyEnabled,
                      interaction.trigger.requiresSpatialInput,
                      interaction.actions.isEmpty,
                      (interaction.accessibilityHint ?? interaction.name) == nil,
                      reported.insert(use.objectId + "\u{1f}" + interaction.id).inserted
                else { return nil }
                let name = names[use.objectId] ?? use.objectId
                return "‘\(name)’ has a \(InteractionSemantics.triggerPhrase(interaction.trigger)) interaction with no response and no spoken description, so assistive technology has nothing meaningful to offer."
            }
        }
    }

    /// Subscribe to the system's accessibility activations for this scene.
    ///
    /// WHY THIS IS LOAD-BEARING. With VoiceOver on, ordinary hand input is not
    /// delivered to the app by default — so an entity can be perfectly labeled,
    /// perfectly discoverable, and completely impossible to activate. Labels
    /// without this are an accessibility claim the product does not honor.
    ///
    /// Both routes converge on `activate(_:)`, so lifetime, enablement,
    /// presence and response ordering are shared with the physical route. There
    /// is exactly one behavior engine.
    private func subscribeAccessibility(in scene: RealityKit.Scene) {
        accessibilitySubscriptions.forEach { $0.cancel() }
        accessibilitySubscriptions = []

        accessibilitySubscriptions.append(
            scene.subscribe(to: AccessibilityEvents.Activate.self) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    // Same resolution as a physical tap, including the ancestry
                    // walk — a labeled USDZ subtree must behave identically.
                    _ = self.handleTap(on: event.entity)
                }
            }
        )
        accessibilitySubscriptions.append(
            scene.subscribe(to: AccessibilityEvents.CustomAction.self) { [weak self] event in
                Task { @MainActor in
                    self?.handleCustomAction(named: String(localized: event.key), on: event.entity)
                }
            }
        )
    }

    /// A custom accessibility action fired. Resolve it back to the exact
    /// interaction that offered it and run THAT one.
    ///
    /// It does not pretend the person approached or grabbed anything. It is an
    /// accessible EQUIVALENT — the same authored response, reached another way.
    func handleCustomAction(named name: String, on entity: Entity) {
        var ancestry: [Entity] = []
        var node: Entity? = entity
        while let current = node { ancestry.append(current); node = current.parent }

        for current in ancestry {
            let entityId = current.name
            if !entityId.isEmpty {
                // A GATE'S accessible equivalent. Published while the gate is
                // waiting (see `setGateAction`), so the label the viewer chose
                // is the one the author wrote.
                if let gateAction = gateActions[entityId], gateAction.label == name {
                    logger.info("Accessibility action ‘\(name)’ → gate on '\(entityId)'")
                    _ = offerToGate?(entityId, gateAction.trigger, false, true)
                    return
                }
                // AN EXPLORE AREA'S EXIT, offered from Area entry (OD-23).
                // The same route: the gate path decides whether the act
                // finishes the Area.
                if let areaExit = areaExitAction, areaExit.entityName == entityId,
                   areaExit.action.label == name {
                    logger.info("Accessibility action ‘\(name)’ → Explore Area exit on '\(entityId)'")
                    _ = offerToGate?(entityId, areaExit.action.trigger, false, true)
                    return
                }
            }
        }

        let candidates: [(id: String, depth: Int, owner: String)] = order.compactMap { id in
            guard let registration = registrations[id], let spec = ledger.spec(id),
                  Self.customActionName(for: spec) == name,
                  let target = resolvedEntity(registration),
                  let depth = ancestry.firstIndex(where: { $0 === target })
            else { return nil }
            return (id, depth, registration.entityId)
        }
        if let candidate = candidates.min(by: { $0.depth < $1.depth }),
           let spec = ledger.spec(candidate.id) {
            logger.info("Accessibility action ‘\(name)’ → interaction '\(candidate.id)'")
            let ran = activateAccessibly(candidate.id)
            _ = offerToGate?(candidate.owner, spec.trigger, ran, true)
            return
        }
        logger.warning("Accessibility action ‘\(name)’ matched no interaction or gate")
    }

    // MARK: - Gate accessibility

    /// The accessible equivalent an ACTIVE gate publishes on its target.
    private struct GateAction: Equatable {
        let label: String
        let trigger: InteractionTrigger
    }
    @ObservationIgnored private var gateActions: [String: GateAction] = [:]

    /// PUBLISH AN ACCESSIBLE EQUIVALENT FOR A WAITING GATE.
    ///
    /// A gate that asks the viewer to face, approach or grab something asks for
    /// a physical act some people cannot perform — and unlike an Interaction,
    /// a gate BLOCKS THE STORY, so without an equivalent the chapter is simply
    /// over for them. This publishes one on the target while the gate waits.
    ///
    /// Event-driven: called from `gateDidStart` / `gateDidEnd`, never polled.
    /// The action does not pretend the person faced or grabbed anything; it is
    /// the accessible route to the same authored narrative condition.
    public func setGateAction(entityName: String, label: String, trigger: InteractionTrigger) {
        gateActions[entityName] = GateAction(label: label, trigger: trigger)
        refreshAccessibilityActions(for: entityName)
    }

    public func clearGateActions() {
        let affected = Array(gateActions.keys)
        gateActions.removeAll()
        for name in affected { refreshAccessibilityActions(for: name) }
    }

    /// The accessible equivalent of an Explore Area's exit, published from
    /// Area ENTRY so an early act is open to everyone (OD-23). Kept apart
    /// from `gateActions`, which a Cue inside the Area clears when it
    /// resolves, while the Area's exit is still open.
    @ObservationIgnored private var areaExitAction: (entityName: String, action: GateAction)?

    public func setAreaExitAction(entityName: String, label: String, trigger: InteractionTrigger) {
        let previous = areaExitAction?.entityName
        areaExitAction = (entityName, GateAction(label: label, trigger: trigger))
        areaTargetNames = [entityName]
        applyCueTargets()
        if let previous, previous != entityName { refreshAccessibilityActions(for: previous) }
        refreshAccessibilityActions(for: entityName)
    }

    public func clearAreaExitAction() {
        guard let previous = areaExitAction?.entityName else { return }
        areaExitAction = nil
        areaTargetNames = []
        applyCueTargets()
        refreshAccessibilityActions(for: previous)
    }

    /// Rebuild one entity's custom actions from its interactions plus any
    /// active gate equivalent. Cheap, and only on a gate transition.
    private func refreshAccessibilityActions(for entityName: String) {
        guard let entity = entityProvider?(entityName),
              var accessibility = entity.components[AccessibilityComponent.self]
        else { return }
        var labels: [LocalizedStringResource] = interactions(on: entityName)
            .filter { ledger.isEffectivelyEnabled($0.id) && $0.trigger.requiresSpatialInput }
            .map { LocalizedStringResource(stringLiteral: Self.customActionName(for: $0)) }
        if let areaExit = areaExitAction, areaExit.entityName == entityName,
           gateActions[entityName]?.label != areaExit.action.label {
            labels.insert(LocalizedStringResource(stringLiteral: areaExit.action.label), at: 0)
        }
        if let gateAction = gateActions[entityName] {
            labels.insert(LocalizedStringResource(stringLiteral: gateAction.label), at: 0)
        }
        accessibility.customActions = labels
        // An entity that only a GATE cares about still has to be reachable.
        accessibility.isAccessibilityElement = true
        entity.components.set(accessibility)
    }

    // MARK: - Affordances and accessibility

    /// Make an object interactive to the SYSTEM: hit-testable, hoverable, and
    /// legible to assistive technology.
    ///
    /// The accessibility half is not optional polish. Feedback that is only
    /// visual is feedback some viewers never receive, so every interactive
    /// object gets an `AccessibilityComponent` regardless of its feedback style
    /// — INCLUDING `.none`, which suppresses a visual affordance and must never
    /// suppress the semantic one.
    private func decorate(_ definition: EntityDefinition,
                          interactions: [InteractionSpec],
                          target: SubElementTarget?,
                          feedback: InteractionFeedbackSpec) {
        let key = target.map { $0.objectId + "\u{1f}" + $0.primPath }
            ?? definition.id
        guard decorated[key] == nil else { return }
        guard let entity = target.flatMap({ subElementProvider?($0) })
                ?? entityProvider?(definition.id)
        else {
            // Not mounted yet. The watches retry, and the affordances are
            // installed on the next `install` after materialization.
            return
        }
        let targetInteractions = interactions.filter { $0.target == target }
        var record = DecorationRecord(ownerId: definition.id, target: target,
                                      addedInputTarget: false, addedCollision: false,
                                      addedHoverEffect: false, addedAccessibility: false,
                                      feedback: feedback)

        // Hit testing. Without a collision shape a tap and a hover have nothing
        // to land on — the entity is visible and inert.
        if entity.components[CollisionComponent.self] == nil {
            let bounds = entity.visualBounds(relativeTo: entity)
            let extents = bounds.extents
            let usable = simd_length(extents) > 0.001
            entity.components.set(CollisionComponent(shapes: [
                usable ? .generateBox(size: extents).offsetBy(translation: bounds.center)
                       : .generateSphere(radius: 0.1)
            ]))
            record.addedCollision = true
        }
        if entity.components[InputTargetComponent.self] == nil {
            entity.components.set(InputTargetComponent())
            record.addedInputTarget = true
        }

        // Visual affordance.
        if let effect = hoverEffect(for: feedback) {
            if entity.components[HoverEffectComponent.self] == nil {
                entity.components.set(effect)
                record.addedHoverEffect = true
            }
        }

        // Semantic affordance.
        if entity.components[AccessibilityComponent.self] == nil,
           let primary = targetInteractions.first(where: \.initiallyEnabled) {
            var accessibility = AccessibilityComponent()
            accessibility.isAccessibilityElement = true
            accessibility.label = LocalizedStringResource(
                stringLiteral: InteractionSemantics.label(for: primary, entity: definition))
            accessibility.value = LocalizedStringResource(
                stringLiteral: InteractionSemantics.hint(for: primary))
            // `.activate` is the system action VoiceOver offers, and it maps to
            // the tap interactions — which is why the custom actions below name
            // the SPATIAL ones a VoiceOver user cannot perform directly.
            accessibility.systemActions = [.activate]
            accessibility.customActions = targetInteractions
                .filter { $0.initiallyEnabled && $0.trigger.requiresSpatialInput }
                .map { LocalizedStringResource(stringLiteral: Self.customActionName(for: $0)) }
            entity.components.set(accessibility)
            record.addedAccessibility = true
        }

        decorated[key] = record
    }

    /// Remove ONLY what `decorate` added. An author who marked an object
    /// grabbable, or a USDZ that shipped with its own collision shapes, keeps
    /// what was theirs.
    private func undecorate(_ entity: Entity, record: DecorationRecord) {
        if record.addedCollision   { entity.components.remove(CollisionComponent.self) }
        if record.addedInputTarget { entity.components.remove(InputTargetComponent.self) }
        if record.addedHoverEffect { entity.components.remove(HoverEffectComponent.self) }
        if record.addedAccessibility { entity.components.remove(AccessibilityComponent.self) }
    }

    /// THE AUTHORED STYLE → THE PLATFORM'S OWN AFFORDANCE.
    ///
    /// `HoverEffectComponent` is the native visionOS mechanism and is what the
    /// system uses for its own interactive content — so `.automatic` is the
    /// stock component with no style, which means it keeps following the
    /// platform as the platform changes. Nothing here is hand-rolled: there is
    /// no custom shader, no per-frame material write and no animation system.
    ///
    /// ACCESSIBILITY IS APPLIED HERE, NOT BOLTED ON AFTER:
    ///
    /// * **Reduce Motion** — `.gentle`'s spotlight sweeps with the viewer's
    ///   viewer's focus, which is motion in the near field. Under Reduce Motion it
    ///   becomes a static highlight instead of being switched OFF: removing the
    ///   affordance would trade a motion problem for a discoverability one.
    /// * **Increase Contrast / Differentiate Without Color** — strength is
    ///   raised so the treatment survives being drawn over busy immersive
    ///   footage. It is a luminance change, not a hue change, so it never
    ///   depends on color alone; and the `AccessibilityComponent` above is a
    ///   non-visual cue that is always present.
    private func hoverEffect(for feedback: InteractionFeedbackSpec) -> HoverEffectComponent? {
        let boost: Float = increasedContrast ? 1.6 : 1.0
        switch feedback.style {
        case .none:
            return nil
        case .automatic:
            // The system's own default, deliberately unparameterized.
            return HoverEffectComponent()
        case .highlight:
            var style = HoverEffectComponent.HighlightHoverEffectStyle.default
            style.strength = min(2.5, (feedback.intensity ?? 1.0) * boost)
            return HoverEffectComponent(.highlight(style))
        case .gentle:
            if reduceMotion {
                var style = HoverEffectComponent.HighlightHoverEffectStyle.default
                style.strength = min(2.5, (feedback.intensity ?? 0.5) * boost)
                return HoverEffectComponent(.highlight(style))
            }
            var style = HoverEffectComponent.SpotlightHoverEffectStyle.default
            style.strength = min(2.5, (feedback.intensity ?? 0.6) * boost)
            return HoverEffectComponent(.spotlight(style))
        }
    }

    // MARK: - Accessibility settings

    private var reduceMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }

    private var increasedContrast: Bool {
        #if canImport(UIKit)
        UIAccessibility.isDarkerSystemColorsEnabled || UIAccessibility.shouldDifferentiateWithoutColor
        #else
        false
        #endif
    }

    /// Re-apply affordances when the viewer changes an accessibility setting
    /// mid-experience. A setting that only takes effect on relaunch is a
    /// setting that does not work.
    private func observeAccessibilitySettings() {
        #if canImport(UIKit)
        let names: [Notification.Name] = [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.differentiateWithoutColorDidChangeNotification
        ]
        accessibilityObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.reapplyFeedback() }
            }
        }
        #endif
    }

    /// Recompute every decorated object's hover effect from the CURRENT
    /// settings. Only the effect is touched; watches, lifetimes and spent-once
    /// records are untouched, because none of them is a display concern.
    public func reapplyFeedback() {
        for (key, var record) in decorated {
            guard let entity = record.target.flatMap({ subElementProvider?($0) })
                    ?? entityProvider?(record.ownerId)
            else { continue }
            let feedback = record.feedback
            if record.addedHoverEffect { entity.components.remove(HoverEffectComponent.self) }
            if let effect = hoverEffect(for: feedback) {
                entity.components.set(effect)
                record.addedHoverEffect = true
            } else {
                record.addedHoverEffect = false
            }
            decorated[key] = record
        }
    }

    /// Stop observing accessibility settings.
    ///
    /// NOT in `deinit`: the observer list is main-actor isolated and `deinit`
    /// is not, so reading it there does not compile. Hosts that discard a
    /// controller call this; `ChapterPlayerCore` owns exactly one for the app's
    /// lifetime, so in practice it is never needed.
    public func stopObservingAccessibilitySettings() {
        #if canImport(UIKit)
        for observer in accessibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        accessibilityObservers.removeAll()
        #endif
    }
}
