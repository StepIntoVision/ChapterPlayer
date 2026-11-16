//
//  EntityActionExecutor.swift
//  SharedVisions
//
//  Handles entity show/hide/move/scale/fade/reveal/gesture/persist actions from SequenceEngine.
//  Wraps RealityKit Entity manipulation. Moves, Scales, Fades and a Reveal's
//  fade-in are computed per frame from ChapterScript's canonical curve
//  (`MotionCurveSampling.actionProgress`, OD-52), not fired as RealityKit
//  animations; see `applyActionTweens`.
//
//  ONE LAYER ORDER, THE EDITORS' (OD-52). Every frame: timed actions, then a
//  legacy `animateMotion` (which the editors fold in with the actions), then
//  the Sequence's animation tracks, then the motion behaviors composed onto
//  whatever pose those produced, with their opacity MULTIPLIED onto the
//  authored or faded opacity. The order and its arithmetic are ChapterScript's
//  (`MotionCurveSampling.composing`, `legacyMotionSample`), the same functions
//  MaestroKit's `ScrubCompositor` and the Mac compositor describe.
//

import RealityKit
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "EntityActionExecutor"
)

// MARK: - Protocol

@MainActor
public protocol EntityActionExecutorProtocol {
    func showEntity(named: String)
    func hideEntity(named: String)
    func moveEntity(_ action: MoveAction)
    func scaleEntity(named: String, multiplier: Float, duration: TimeInterval, timing: SegmentTimingFunction)
    func fadeEntity(_ action: FadeAction)
    func revealEntity(_ action: RevealAction)
    func enableGesture(named: String)
    func disableGesture(named: String)
    func resetAllEntities()
    func persistEntity(named: String)
    func unpersistEntity(named: String)
    func beginMotion(_ action: AnimateMotionAction)
    func beginMotionBehavior(_ behavior: ChapterScript.MotionBehaviorDTO)
    func clearAllMotions()
    /// Clear only the SEGMENT-SCOPED motions. See the implementation for why
    /// Motion Actions 2.0 behaviors are deliberately not among them.
    func clearSegmentMotions()
    func applyActiveMotions(segmentElapsed: TimeInterval, totalElapsed: TimeInterval)
    func setSequenceAnimation(tracks: [EntityAnimationTrack], clock: (@MainActor () -> TimeInterval)?)
    /// Show When Memory Matches (format 10, OD-145): the Objects Memory holds
    /// back right now. `freshVisit` is true on a Sequence entry.
    func setHeldBackByMemory(_ names: Set<String>, freshVisit: Bool)
}

/// Default no-op so existing conformers outside this package keep compiling;
/// the real executor overrides it.
public extension EntityActionExecutorProtocol {
    func setSequenceAnimation(tracks: [EntityAnimationTrack], clock: (@MainActor () -> TimeInterval)?) {}
    func beginMotionBehavior(_ behavior: ChapterScript.MotionBehaviorDTO) {}
    /// Defaults to the old behavior for conformers outside this package, which
    /// never had Motion Actions 2.0 to keep alive in the first place.
    func clearSegmentMotions() { clearAllMotions() }
    func setHeldBackByMemory(_ names: Set<String>, freshVisit: Bool) {}
}

// MARK: - Implementation

@MainActor
public final class EntityActionExecutor: EntityActionExecutorProtocol {


    public init() {}

    // MARK: Show When Memory Matches (format 10, OD-145)

    /// THE OBJECTS MEMORY HOLDS BACK in the playing Sequence. Such an Object
    /// stays disabled whatever the Timeline says; Show, Hide and Reveal still
    /// run on it and record what the Timeline wants (`timelineWantsShown`),
    /// so the moment Memory lets it go it appears exactly as the Timeline
    /// left it — revealed and faded in, or hidden. The engine recomputes the
    /// set on every Sequence entry and after every Memory change.
    public private(set) var heldBackByMemory: Set<String> = []
    private var timelineWantsShown: [String: Bool] = [:]

    public func setHeldBackByMemory(_ names: Set<String>, freshVisit: Bool) {
        if freshVisit {
            // A new visit starts from the reset state: nothing is owed.
            heldBackByMemory = []
            timelineWantsShown = [:]
        }
        let released = heldBackByMemory.subtracting(names)
        let newlyHeld = names.subtracting(heldBackByMemory)
        heldBackByMemory = names
        for name in newlyHeld {
            guard let entity = entityRegistry[name] else { continue }
            timelineWantsShown[name] = entity.isEnabled
            entity.isEnabled = false
        }
        for name in released {
            let wanted = timelineWantsShown.removeValue(forKey: name) ?? false
            guard wanted, let entity = entityRegistry[name] else { continue }
            entity.isEnabled = true
            logger.debug("Memory lets '\(name)' show")
        }
    }

    /// After an action enabled or disabled a held-back Object: remember what
    /// the Timeline wants, and keep it disabled.
    private func holdIfMemorySays(_ name: String, _ entity: Entity) {
        guard heldBackByMemory.contains(name) else { return }
        timelineWantsShown[name] = entity.isEnabled
        entity.isEnabled = false
    }

    /// Registry of named entities. Populated by ImmersiveView during setup.
    public var entityRegistry: [String: Entity] = [:]

    /// Original transforms for reset support.
    private var originalTransforms: [String: Transform] = [:]

    /// Names of entities that should survive sequence transitions.
    /// Populated by `.persistEntity` segment actions; respected by `resetAllEntities()`.
    public var persistedEntityNames: Set<String> = []

    /// Per-entity active motion curves. Populated by `.animateMotion` segment actions;
    /// cleared at every segment boundary by `clearAllMotions()`.
    /// `applyActiveMotions(segmentElapsed:totalElapsed:)` samples each entry per frame
    /// and writes the result back to the entity's transform.
    ///
    /// `startedAt` is the AUTHORED sequence time at which the motion began, and
    /// it is what progress is measured from. It used to be measured from the
    /// SEGMENT's start instead, which meant a motion scheduled 5s into a 10s segment
    /// began life already 50% complete — while the editor's `ScrubCompositor`
    /// drew the same motion from its beginning. The author saw one thing and
    /// the headset did another. Both now call `MotionProgress`.
    ///
    /// nil when no authored clock was available at registration; the sampler
    /// then falls back to the old segment-relative behavior rather than freezing.
    private var activeMotions: [String: (action: AnimateMotionAction, startedAt: TimeInterval?, serial: Int)] = [:]

    /// THE ACTION LAYER'S OWN POSE, per entity, in parent space (OD-52).
    ///
    /// What the timed actions (Move, Scale, a placing Reveal) and a legacy
    /// `animateMotion` last set, BEFORE the motion layer composed anything onto
    /// it. The behavior layer composes onto this for an unkeyed Object, as the
    /// editors compose onto their action walk's pose; reading
    /// `entity.transform` instead would fold the previous frame's offset back
    /// in. Absent means the action layer has not moved the Object since its
    /// rest was (re)applied, so the authored rest is the answer.
    private var actionPoses: [String: Transform] = [:]

    /// THE ACTION LAYER'S OWN OPACITY, per entity: what a Fade, a Reveal or a
    /// Show last set, before a fading behavior multiplied onto it. Absent
    /// means nothing has set one, and the entity's own opacity is read (once,
    /// before the motion layer first writes it).
    private var actionOpacities: [String: Float] = [:]

    /// Execution order of the transform-writing actions, so a legacy
    /// `animateMotion` and a Move on one Object resolve as the editors' time
    /// walk does: the one that fired LATER wins.
    private var actionSerial = 0
    private var transformActionSerials: [String: Int] = [:]

    /// MOTION ACTIONS 2.0 — active behaviors per entity, MANY per entity
    /// (a Move In and a Scale In are two behaviors that compose), each with
    /// the authored time it started. Cleared with the legacy motions.
    ///
    /// A behavior is an OFFSET: it is re-applied every frame on top of the
    /// pose the authored layers produce, never accumulated into the entity —
    /// so it cannot drift, and removing it restores the authored pose exactly.
    private var activeBehaviors: [String: [(behavior: ChapterScript.MotionBehaviorDTO, startedAt: TimeInterval?)]] = [:]

    /// Sequence-level animation tracks, registered once at sequence start and
    /// sampled every frame on the AUTHORED sequence clock (`animationClock`) —
    /// not wall time, so gates and pauses hold curves instead of skipping
    /// them. Independent of the per-segment `activeMotions` above (which stay
    /// for legacy documents).
    private var sequenceAnimationTracks: [EntityAnimationTrack] = []
    private var animationClock: (@MainActor () -> TimeInterval)?

    /// Closure that samples the user's head transform at call time.
    /// Wired by ImmersiveView during setup. Returns nil when tracking is unavailable.
    public var headTransformProvider: (() -> Transform?)?

    /// Fallback head transform for simulator / tracking-unavailable.
    /// Simulated eye height at world origin, facing -Z.
    private let simulatorFallbackTransform = Transform(
        scale: .one,
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
        translation: SIMD3<Float>(0, 1.5, 0)
    )

    /// Register an entity with a name for the sequence engine to reference.
    public func register(_ entity: Entity, name: String) {
        entityRegistry[name] = entity
        originalTransforms[name] = entity.transform
    }

    /// Drop a registered entity name. Called by `DocumentEntityLoader.unload`
    /// when the loaded document changes (live hot-reload, project switch),
    /// so old sequence actions referencing a stale name fail safely instead
    /// of operating on the deleted Entity.
    public func unregister(name: String) {
        entityRegistry.removeValue(forKey: name)
        originalTransforms.removeValue(forKey: name)
        transformTweens.removeValue(forKey: name)
        opacityTweens.removeValue(forKey: name)
        actionPoses.removeValue(forKey: name)
        actionOpacities.removeValue(forKey: name)
        transformActionSerials.removeValue(forKey: name)
    }

    /// Re-baseline the reset pose for `name` to a new AUTHORED transform.
    /// Live editors call this when a committed edit changes the entity's
    /// base transform (the snapshot is otherwise captured only at
    /// materialize, so every replay's `resetAllEntities` would snap the
    /// entity back to its materialize-time pose — the "default placement"
    /// for assets imported and then positioned in-session).
    public func setOriginalTransform(_ transform: Transform, name: String) {
        guard originalTransforms[name] != nil else { return }
        originalTransforms[name] = transform
        // The rest moved under the action layer: it starts again from there.
        actionPoses.removeValue(forKey: name)
    }

    // MARK: - The action layer's state (OD-52)

    /// The parent-space pose the action layer last set, else the authored
    /// rest when the motion layer may have written over the rendered pose,
    /// else the rendered pose (nothing but the action layer has touched it).
    private func actionPose(for name: String, _ entity: Entity) -> Transform {
        // A GRABBABLE OBJECT AT REST IS WHERE THE VIEWER PUT IT. A Reveal
        // that allows grabbing adds ManipulationComponent, and nothing tells
        // this layer when the viewer moves the Object by hand, so the cached
        // pose went stale: a later Scale or offset Move started from where
        // the Reveal placed it and the Object jumped back (round 4 review).
        // With no tween and no motion behavior running, the rendered pose
        // IS the action pose plus the viewer's grab; read it.
        if entity.components[ManipulationComponent.self] != nil,
           transformTweens[name] == nil, activeBehaviors[name] == nil,
           !activeMotions.values.contains(where: { $0.action.entity == name }) {
            return entity.transform
        }
        if let pose = actionPoses[name] { return pose }
        if activeBehaviors[name] != nil, let rest = authoredRestTransform(for: name) { return rest }
        return entity.transform
    }

    /// The opacity the action layer last set, else the entity's own.
    private func actionOpacity(for name: String, _ entity: Entity) -> Float {
        actionOpacities[name] ?? entity.opacity
    }

    /// Write an action-layer opacity and remember it as the base the motion
    /// layer multiplies onto.
    private func setActionOpacity(_ value: Float, on entity: Entity, name: String) {
        actionOpacities[name] = value
        entity.opacity = value
    }

    /// A parent-space pose expressed in world space.
    private static func worldTransform(of local: Transform, in entity: Entity) -> Transform {
        guard let parent = entity.parent else { return local }
        return Transform(matrix: parent.transformMatrix(relativeTo: nil) * local.matrix)
    }

    /// A world-space pose expressed in the entity's parent space.
    private static func localTransform(ofWorld world: Transform, in entity: Entity) -> Transform {
        guard let parent = entity.parent else { return world }
        return Transform(matrix: parent.transformMatrix(relativeTo: nil).inverse * world.matrix)
    }

    /// Record that a transform-writing action fired now, after everything
    /// already in flight.
    private func noteTransformAction(on name: String) {
        actionSerial += 1
        transformActionSerials[name] = actionSerial
    }

    public func showEntity(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("showEntity: '\(name)' not found in registry")
            return
        }
        entity.isEnabled = true
        // A stale fully-transparent OpacityComponent (video preheat, a
        // gated video start that never revealed, or a fadeEntity-to-0 used
        // as a hide) makes "show" a silent no-op — the entity is enabled
        // but renders nothing. Show means visible: snap effectively-zero
        // opacity back to 1. Partial opacities are authored state and are
        // left alone.
        if let opacity = entity.components[OpacityComponent.self]?.opacity,
           opacity <= 0.001 {
            entity.components[OpacityComponent.self]?.opacity = 1
        }
        if let base = actionOpacities[name], base <= 0.001 {
            actionOpacities[name] = 1
        }
        triggerParticleBurstIfNeeded(on: entity)
        holdIfMemorySays(name, entity)
        logger.debug("Show entity: \(name)")
    }

    /// Non-looping particle entities (`ParticleBurstOnRevealComponent`)
    /// are built idle with a preset-sized `burstCount`; showing/revealing
    /// them fires the one-shot burst. Re-revealing re-bursts.
    private func triggerParticleBurstIfNeeded(on entity: Entity) {
        guard entity.components.has(ParticleBurstOnRevealComponent.self),
              var emitter = entity.components[ParticleEmitterComponent.self] else { return }
        emitter.burst()
        entity.components.set(emitter)
    }

    public func hideEntity(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("hideEntity: '\(name)' not found in registry")
            return
        }
        entity.isEnabled = false
        holdIfMemorySays(name, entity)
        logger.debug("Hide entity: \(name)")
    }

    public func moveEntity(_ action: MoveAction) {
        guard let entity = entityRegistry[action.entity] else {
            logger.warning("moveEntity: '\(action.entity)' not found in registry")
            return
        }

        let timing = action.timing.animationTimingFunction
        let canonicalTiming = Self.canonicalTiming(action.timing)

        if let headOffset = action.headRelativePosition {
            let worldTarget = resolveHeadWorldPosition(offset: headOffset, headYOnly: action.headYOnly)

            // From the ACTION pose, not the rendered one: a Slow Spin or a
            // Pulse composed on top must not be baked into the Move's target.
            let current = Self.worldTransform(of: actionPose(for: action.entity, entity), in: entity)
            var targetScale = current.scale
            var targetRotation = current.rotation

            if let multiplier = action.scaleMultiplier {
                targetScale *= multiplier
            }
            if let absolute = action.absoluteScale {
                targetScale = absolute
            }
            if let absRot = action.absoluteRotation {
                targetRotation = absRot
            } else if let offset = action.rotationOffset {
                targetRotation = offset * targetRotation
            }

            let targetTransform = Transform(
                scale: targetScale,
                rotation: targetRotation,
                translation: worldTarget
            )

            // SAMPLED PER FRAME on the canonical curve (OD-52), in WORLD space
            // because the target was resolved there. RealityKit's own easing is
            // only the fallback when no authored clock is installed.
            if !startTransformTween(on: entity, name: action.entity, to: targetTransform,
                                    world: true, duration: action.duration,
                                    timing: canonicalTiming) {
                entity.move(to: targetTransform, relativeTo: nil, duration: action.duration, timingFunction: timing)
                actionPoses[action.entity] = Self.localTransform(ofWorld: targetTransform, in: entity)
                noteTransformAction(on: action.entity)
            }

            let mode = action.headYOnly ? "headYOnly" : "headRelative"
            logger.debug("Move entity (\(mode)): \(action.entity) offset=\(headOffset) → world=\(worldTarget)")
        } else {
            // Parent-space positioning, from the ACTION pose.
            let current = actionPose(for: action.entity, entity)
            var targetPosition = current.translation
            var targetScale = current.scale
            var targetRotation = current.rotation

            if let offset = action.positionOffset {
                targetPosition += offset
            }
            if let absolute = action.absolutePosition {
                targetPosition = absolute
            }
            if let multiplier = action.scaleMultiplier {
                targetScale *= multiplier
            }
            if let absolute = action.absoluteScale {
                targetScale = absolute
            }
            if let absRot = action.absoluteRotation {
                targetRotation = absRot
            } else if let offset = action.rotationOffset {
                targetRotation = offset * targetRotation
            }

            let targetTransform = Transform(
                scale: targetScale,
                rotation: targetRotation,
                translation: targetPosition
            )

            if !startTransformTween(on: entity, name: action.entity, to: targetTransform,
                                    world: false, duration: action.duration,
                                    timing: canonicalTiming) {
                entity.move(to: targetTransform, relativeTo: entity.parent, duration: action.duration, timingFunction: timing)
                actionPoses[action.entity] = targetTransform
                noteTransformAction(on: action.entity)
            }

            logger.debug("Move entity: \(action.entity) over \(String(format: "%.1f", action.duration))s")
        }
    }

    public func scaleEntity(named name: String, multiplier: Float, duration: TimeInterval, timing: SegmentTimingFunction) {
        guard let entity = entityRegistry[name] else {
            logger.warning("scaleEntity: '\(name)' not found in registry")
            return
        }

        let current = actionPose(for: name, entity)
        let targetTransform = Transform(
            scale: current.scale * multiplier,
            rotation: current.rotation,
            translation: current.translation
        )

        if !startTransformTween(on: entity, name: name, to: targetTransform, world: false,
                                duration: duration, timing: Self.canonicalTiming(timing)) {
            entity.move(
                to: targetTransform,
                relativeTo: entity.parent,
                duration: duration,
                timingFunction: timing.animationTimingFunction
            )
            actionPoses[name] = targetTransform
            noteTransformAction(on: name)
        }

        logger.debug("Scale entity: \(name) by \(multiplier)× over \(String(format: "%.1f", duration))s")
    }

    public func fadeEntity(_ action: FadeAction) {
        guard let entity = entityRegistry[action.entity] else {
            logger.warning("fadeEntity: '\(action.entity)' not found in registry")
            return
        }
        if !startOpacityTween(on: entity, name: action.entity, to: action.opacity,
                              duration: action.duration,
                              timing: Self.canonicalTiming(action.timing)) {
            entity.fadeOpacity(to: action.opacity, duration: action.duration, timing: action.timing.animationTimingFunction)
            actionOpacities[action.entity] = action.opacity
        }
        logger.debug("Fade entity: \(action.entity) to opacity \(action.opacity) over \(String(format: "%.1f", action.duration))s")
    }

    public func revealEntity(_ action: RevealAction) {
        guard let entity = entityRegistry[action.entity] else {
            logger.warning("revealEntity: '\(action.entity)' not found in registry")
            return
        }

        // 1. Snap invisible (synchronous — no frame rendered between this and enable)
        opacityTweens.removeValue(forKey: action.entity)
        setActionOpacity(0, on: entity, name: action.entity)
        // A Reveal that PLACES the entity ends any Move still in flight on it,
        // or the next frame's sample would carry it off the placement.
        if action.headRelativePosition != nil || action.position != nil || action.scale != nil {
            transformTweens.removeValue(forKey: action.entity)
        }

        // 2. Position, ASSIGNED from the action pose (the motion layer's
        //    offsets are not the Object's placement). Assigned rather than
        //    `move(to:duration: 0)`, which goes through the animation system
        //    and does nothing for an entity outside a scene, as
        //    `resetAllEntities` explains.
        if let headOffset = action.headRelativePosition {
            let worldTarget = resolveHeadWorldPosition(offset: headOffset, headYOnly: action.headYOnly)
            let current = Self.worldTransform(of: actionPose(for: action.entity, entity), in: entity)
            var targetScale = current.scale
            if let scale = action.scale { targetScale = scale }
            let targetTransform = Transform(
                scale: targetScale,
                rotation: current.rotation,
                translation: worldTarget
            )
            Self.write(targetTransform, to: entity, world: true)
        } else if let position = action.position {
            var target = actionPose(for: action.entity, entity)
            target.translation = position
            if let scale = action.scale { target.scale = scale }
            Self.write(target, to: entity, world: false)
        }

        // 3. Scale (only if not already applied in position block above)
        if let scale = action.scale, action.headRelativePosition == nil, action.position == nil {
            var target = actionPose(for: action.entity, entity)
            target.scale = scale
            Self.write(target, to: entity, world: false)
        }
        if action.headRelativePosition != nil || action.position != nil || action.scale != nil {
            actionPoses[action.entity] = entity.transform
            noteTransformAction(on: action.entity)
        }

        // 4. Enable (still invisible — opacity 0), unless Memory holds it
        //    back: then the fade still runs, and the Object appears at its
        //    revealed opacity the moment Memory lets it go (OD-145).
        entity.isEnabled = true
        holdIfMemorySays(action.entity, entity)

        // 5. Fade in (or cut-in if duration == 0), on the CANONICAL REVEAL
        //    CURVE (`MotionCurveSampling.revealTiming`, OD-52), sampled per
        //    frame. RealityKit's `.easeInOut` is only the no-clock fallback.
        if !startOpacityTween(on: entity, name: action.entity, to: 1.0,
                              duration: action.fadeIn,
                              timing: MotionCurveSampling.revealTiming) {
            entity.fadeOpacity(to: 1.0, duration: action.fadeIn)
            actionOpacities[action.entity] = 1
        }

        // 6. Optional hand manipulation — make the entity grabbable /
        //    movable / rotatable / scalable by the viewer. RealityKit's
        //    ManipulationComponent.configureEntity wires up the collision
        //    + input-target + hover-effect components it needs.
        if action.manipulable {
            ManipulationComponent.configureEntity(entity)
        }

        // 7. Non-looping particle emitters fire their one-shot burst now.
        triggerParticleBurstIfNeeded(on: entity)

        logger.debug("Reveal entity: \(action.entity) fadeIn=\(String(format: "%.1f", action.fadeIn))s manipulable=\(action.manipulable)")
    }

    // MARK: - Head Position Helper

    private func resolveHeadWorldPosition(offset: SIMD3<Float>, headYOnly: Bool) -> SIMD3<Float> {
        let headTransform: Transform
        if let sampled = headTransformProvider?() {
            headTransform = sampled
        } else {
            logger.info("Head tracking unavailable — using simulator fallback position")
            headTransform = simulatorFallbackTransform
        }

        if headYOnly {
            let headWorldY = headTransform.translation.y
            return SIMD3<Float>(offset.x, headWorldY + offset.y, offset.z)
        } else {
            return headTransform.worldPosition(forLocalOffset: offset)
        }
    }

    /// RESET MEANS "RETURN TO THE AUTHORED REST FOR THE SEQUENCE IN CONTEXT".
    ///
    /// This used to move every entity to `originalTransforms` — the
    /// CHAPTER-global rest — and ignore `sequenceRestOverrides` entirely. Every
    /// path into a Sequence goes `playSequence` → `applyRestPlacements` →
    /// `SequenceEngine.play` → `stop(resetEntities: true)` → here, so a
    /// Sequence-local placement was applied and then **immediately wiped**, one
    /// call later, before the first frame. The object played from its
    /// Chapter-global pose while `restTransformData` — which DID consult the
    /// overrides — fed the local one to the animation evaluator, so an
    /// unanimated object sat at one pose and an animated one jumped to another
    /// the moment its first sample landed.
    ///
    /// Resolving it here rather than re-ordering the calls is deliberate: the
    /// executor is the thing that knows what an entity's rest IS, and a fix
    /// that depends on two call sites staying in a particular order is one
    /// refactor away from breaking again. It is also why nothing re-applies the
    /// placement per frame — this runs once per Sequence entry, exactly as
    /// before.
    public func resetAllEntities() {
        clearAllMotions()
        for name in originalTransforms.keys {
            guard let entity = entityRegistry[name] else { continue }
            if persistedEntityNames.contains(name) {
                logger.debug("resetAllEntities: skipping persisted entity '\(name)'")
                continue
            }
            guard let restTransform = authoredRestTransform(for: name) else { continue }
            // ASSIGNED, NOT ANIMATED. `move(to:relativeTo:duration: 0)` is the
            // animation API asked to take no time, and it is not equivalent: it
            // goes through RealityKit's animation system, which does nothing
            // for an entity that is not in a scene — so a reset that ought to
            // be a plain state restore silently did nothing in exactly the
            // conditions a test can create, and depends on scene membership on
            // device. `transform` IS parent-relative, so this is the same
            // pose by definition, and it is what `applyRestPlacements` two
            // methods below has always done. One restore, one mechanism.
            entity.transform = restTransform
            actionPoses.removeValue(forKey: name)
            actionOpacities.removeValue(forKey: name)
            if entity.components.has(OpacityComponent.self) {
                entity.opacity = 1.0
            }
            // Return to the canonical "default" state — hidden until a sequence action reveals it.
            entity.isEnabled = false
        }
        logger.info("Reset all entity transforms and disabled non-persisted entities")
    }

    // MARK: - Timed actions sampled per frame (OD-52)

    /// A Move or Scale in flight, sampled every frame on the AUTHORED Sequence
    /// clock from ChapterScript's canonical curve.
    ///
    /// THE HEADSET COMPUTES THE POSE; IT NO LONGER FIRES REALITYKIT'S EASING.
    /// The owner decided (2026-11-14, OD-52) that the Mac's quadratic curve is
    /// canonical. `entity.move(to:duration:timingFunction:)` eased with
    /// RealityKit's `.easeInOut`, a different shape, and ran on wall time, so
    /// it also kept going while a gate or a pause held the authored clock.
    /// `MotionCurveSampling.actionProgress` is the function the Mac compositor
    /// and MaestroKit's `ScrubCompositor` call for the same action.
    private struct TransformTween {
        let startedAt: TimeInterval
        let duration: TimeInterval
        let timing: ChapterScript.SegmentTimingFunction
        let from: Transform
        let to: Transform
        /// True when `from` and `to` are WORLD space (a head-relative Move,
        /// whose target was resolved there); otherwise parent space.
        let world: Bool
    }

    /// A Fade or a Reveal's fade-in in flight, sampled like `TransformTween`.
    private struct OpacityTween {
        let startedAt: TimeInterval
        let duration: TimeInterval
        let timing: ChapterScript.SegmentTimingFunction
        let from: Float
        let to: Float
    }

    /// One in-flight transform action per entity: a new Move or Scale on the
    /// same entity starts from where the old one has carried it, and replaces
    /// it, as a second RealityKit `move(to:)` did.
    private var transformTweens: [String: TransformTween] = [:]
    /// One in-flight opacity action per entity, independent of the transform.
    private var opacityTweens: [String: OpacityTween] = [:]

    /// The runtime's own timing enum spelled as the format's, so the curve is
    /// looked up in the ONE table. The raw values are the same strings.
    private static func canonicalTiming(_ timing: SegmentTimingFunction) -> ChapterScript.SegmentTimingFunction {
        ChapterScript.SegmentTimingFunction(rawValue: timing.rawValue) ?? .easeInOut
    }

    /// Start sampling a Move or Scale toward `target`. Returns false only when
    /// no authored clock is installed, so the caller falls back to RealityKit's
    /// animation rather than freezing the entity. An instant (duration no
    /// longer than `MotionProgress.minimumDuration`) is assigned at once.
    private func startTransformTween(
        on entity: Entity, name: String, to target: Transform, world: Bool,
        duration: TimeInterval, timing: ChapterScript.SegmentTimingFunction
    ) -> Bool {
        if duration <= MotionProgress.minimumDuration {
            transformTweens.removeValue(forKey: name)
            Self.write(target, to: entity, world: world)
            actionPoses[name] = entity.transform
            noteTransformAction(on: name)
            return true
        }
        guard let now = animationClock?() else { return false }
        // FROM THE ACTION POSE, never the rendered one, which carries the
        // motion layer's offset of the last frame.
        let local = actionPose(for: name, entity)
        let from = world ? Self.worldTransform(of: local, in: entity) : local
        transformTweens[name] = TransformTween(startedAt: now, duration: duration, timing: timing,
                                               from: from, to: target, world: world)
        noteTransformAction(on: name)
        return true
    }

    /// Start sampling a Fade (or a Reveal's fade-in) toward `target`, from the
    /// entity's opacity now. Same fallback and instant rules as
    /// `startTransformTween`.
    private func startOpacityTween(
        on entity: Entity, name: String, to target: Float,
        duration: TimeInterval, timing: ChapterScript.SegmentTimingFunction
    ) -> Bool {
        if duration <= MotionProgress.minimumDuration {
            opacityTweens.removeValue(forKey: name)
            setActionOpacity(target, on: entity, name: name)
            return true
        }
        guard let now = animationClock?() else { return false }
        opacityTweens[name] = OpacityTween(startedAt: now, duration: duration, timing: timing,
                                           from: actionOpacity(for: name, entity), to: target)
        return true
    }

    private static func write(_ transform: Transform, to entity: Entity, world: Bool) {
        if world {
            entity.setTransformMatrix(transform.matrix, relativeTo: nil)
        } else {
            entity.transform = transform
        }
    }

    /// Write every in-flight Move, Scale and Fade at the authored clock's now.
    ///
    /// A finished one writes its target exactly and is dropped. A clock that
    /// reads EARLIER than a tween's start has been rebased (a seek, a new
    /// Sequence on the same executor): that tween is finished at its target
    /// rather than held at its start, which is where RealityKit's wall-time
    /// animation would long since have left it.
    private func applyActionTweens() {
        guard !transformTweens.isEmpty || !opacityTweens.isEmpty,
              let now = animationClock?() else { return }
        for (name, tween) in transformTweens {
            guard let entity = entityRegistry[name] else {
                transformTweens.removeValue(forKey: name)
                continue
            }
            let rebased = now < tween.startedAt
            let done = rebased || MotionProgress.isComplete(startTime: tween.startedAt, now: now,
                                                            duration: tween.duration)
            let progress = done ? 1 : MotionCurveSampling.actionProgress(
                startTime: tween.startedAt, now: now, duration: tween.duration, timing: tween.timing)
            let pose = MotionCurveSampling.interpolatedPose(
                from: (tween.from.translation, tween.from.rotation, tween.from.scale),
                to: (tween.to.translation, tween.to.rotation, tween.to.scale),
                progress: progress)
            Self.write(Transform(scale: pose.scale, rotation: pose.rotation, translation: pose.position),
                       to: entity, world: tween.world)
            actionPoses[name] = entity.transform
            if done { transformTweens.removeValue(forKey: name) }
        }
        for (name, tween) in opacityTweens {
            guard let entity = entityRegistry[name] else {
                opacityTweens.removeValue(forKey: name)
                continue
            }
            let rebased = now < tween.startedAt
            let done = rebased || MotionProgress.isComplete(startTime: tween.startedAt, now: now,
                                                            duration: tween.duration)
            let progress = done ? 1 : MotionCurveSampling.actionProgress(
                startTime: tween.startedAt, now: now, duration: tween.duration, timing: tween.timing)
            setActionOpacity(MotionCurveSampling.interpolatedOpacity(from: tween.from, to: tween.to,
                                                                     progress: progress),
                             on: entity, name: name)
            if done { opacityTweens.removeValue(forKey: name) }
        }
    }

    // MARK: - Active motion

    public func beginMotionBehavior(_ behavior: ChapterScript.MotionBehaviorDTO) {
        guard entityRegistry[behavior.entity] != nil else {
            logger.warning("beginMotionBehavior: entity '\(behavior.entity)' not found in registry")
            return
        }
        activeBehaviors[behavior.entity, default: []].append((behavior, animationClock?()))
    }

    public func beginMotion(_ action: AnimateMotionAction) {
        guard entityRegistry[action.entity] != nil else {
            logger.warning("beginMotion: entity '\(action.entity)' not found in registry")
            return
        }
        // Stamp the authored clock NOW, so progress is measured from when this
        // motion actually started rather than from whenever its segment did.
        actionSerial += 1
        activeMotions[action.entity] = (action, animationClock?(), actionSerial)
        logger.debug("beginMotion: \(action.entity) (duration \(action.duration)s)")
    }

    public func clearAllMotions() {
        if !activeMotions.isEmpty {
            logger.debug("Cleared \(self.activeMotions.count) active motion(s)")
        }
        activeMotions.removeAll(keepingCapacity: true)
        activeBehaviors.removeAll(keepingCapacity: true)
        // A reset assigns the rest pose; a Move or Fade still sampling would
        // carry the entity straight off it on the next frame.
        transformTweens.removeAll(keepingCapacity: true)
        opacityTweens.removeAll(keepingCapacity: true)
        transformActionSerials.removeAll(keepingCapacity: true)
    }

    /// A SEGMENT BOUNDARY ENDS A LEGACY MOTION AND DOES NOT END A BEHAVIOR.
    ///
    /// `animateMotion` is per-segment by design — it is sampled on `segmentElapsed`
    /// and the engine's comment at the call site says so. Motion Actions 2.0
    /// behaviors were swept into the same call only because they were added to
    /// the dictionary next door, and clearing them at a boundary is wrong for
    /// three reasons:
    ///
    ///   1. A behavior is timed on the AUTHORED SEQUENCE CLOCK through
    ///      `startedAt` + `MotionProgress`, whose progress SATURATES at 1. It
    ///      has a natural end of its own and does not need a boundary to stop
    ///      it; past that point it simply holds its final offset.
    ///   2. Clearing one restores the authored rest pose, so an EXIT that had
    ///      finished faded the object out and then a segment boundary popped it
    ///      back to full opacity at its original position.
    ///   3. The editor never scoped them this way. `SequencePreviewCompositor`
    ///      walks every timed entry at or before the playhead with no segment
    ///      scoping at all, so the Mac showed a behavior persisting while the
    ///      headset dropped it — the editor and the device disagreeing about
    ///      the same authored fact, which is the failure the `startedAt` work
    ///      above this file was done to remove.
    ///
    /// A behavior is re-applied as an OFFSET from the authored base every
    /// frame and never accumulates, so keeping one costs nothing and cannot
    /// drift.
    ///
    /// AND A LEGACY MOTION STILL IN FLIGHT KEEPS RUNNING. Clearing every
    /// `animateMotion` at the boundary froze an object mid-move: it writes
    /// the transform absolutely each frame, so once its entry is gone nothing
    /// moves it again. The editor has never scoped these to a Segment
    /// (`ScrubCompositor` samples from the motion's own start), so the Mac
    /// showed the move finishing and the headset showed it stop. It matters
    /// more now that an Explore Area edit moves Segment boundaries freely. A
    /// motion on the authored clock has a natural end; it is dropped at the
    /// first boundary AFTER it saturates, where dropping it changes nothing.
    /// An unclocked one (the segment-relative fallback) is still Segment-scoped,
    /// because its progress would restart against the next Segment's clock.
    public func clearSegmentMotions() {
        let now = animationClock?()
        let before = activeMotions.count
        activeMotions = activeMotions.filter { _, entry in
            guard let startedAt = entry.startedAt, let now else { return false }
            return !MotionProgress.isComplete(startTime: startedAt, now: now,
                                              duration: entry.action.duration)
        }
        if before != activeMotions.count {
            logger.debug("Cleared \(before - self.activeMotions.count) finished segment motion(s); \(self.activeMotions.count) still running")
        }
    }

    public func setSequenceAnimation(tracks: [EntityAnimationTrack], clock: (@MainActor () -> TimeInterval)?) {
        sequenceAnimationTracks = tracks.filter { $0.hasAnyKeys }
        animationClock = clock
        if !sequenceAnimationTracks.isEmpty {
            logger.info("Sequence animation: \(self.sequenceAnimationTracks.count) track(s) registered")
        }
    }

    /// MOTION ACTIONS 2.0 — compose every active behavior onto the pose the
    /// authored layers just produced.
    ///
    /// Runs AFTER the action layer and `applySequenceAnimationTracks()` on
    /// purpose: the base is what those produced, and a behavior only ever
    /// ADDS to it. The base is read from AUTHORED state, never from the
    /// entity's current on-screen transform, which would fold the previous
    /// frame's offset back in and make the object walk away over time:
    ///
    ///   a KEYED Object    the pose its track wrote THIS frame;
    ///   an UNKEYED one    the action layer's pose (`actionPoses`: where a
    ///                     Move, a Scale, a placing Reveal or a legacy motion
    ///                     put it), else its authored rest.
    ///
    /// That is the editors' rule (`ScrubCompositor`, the Mac compositor): the
    /// offset composes onto the post-action, post-track pose. Before OD-52 an
    /// unkeyed Object's behaviors composed onto its REST, so a Float on a
    /// moved Object snapped it back to where it started.
    ///
    /// OPACITY MULTIPLIES, AND ONLY A FADING BEHAVIOR TOUCHES IT (VRT-10). A
    /// behavior's opacity multiplier goes onto the authored or faded opacity
    /// (the track's, when it keys opacity, else the action layer's), as in
    /// the editors; it used to REPLACE it, so an Object faded to 0.3 popped
    /// to full opacity when an entrance finished, and a Float with no fade
    /// still removed the `OpacityComponent` a Fade had set.
    private func applyActiveBehaviors() {
        guard !activeBehaviors.isEmpty else { return }
        let authoredNow = animationClock?()
        // NO LIVE HEAD YAW, DELIBERATELY. The scene root is rebased to the
        // head when a Sequence starts (`rebaseSceneRootToHead`), so the root's
        // own axes ARE the viewer's axes — and that rebase is the stable one
        // an author aimed at. Reading the head every frame instead would make
        // "enter from the left" depend on where the viewer happened to be
        // looking at the moment the motion fired, so the same authored Chapter
        // would play differently on every run and would never match the
        // editor. `nil` means "viewer space is this space", which is exactly
        // what the Mac Viewer also assumes (camera at the origin facing -Z).
        let viewerYaw: Float? = nil

        for (name, entries) in activeBehaviors {
            guard let entity = entityRegistry[name] else { continue }
            // RESOLVED BEFORE the behaviors rather than after: an orbit is
            // defined by its center and a center entrance by the vector to
            // the origin, so the resolver needs to know where the object sits.
            //
            // THE KEYED BRANCH READS `entity.transform` ONLY BECAUSE THE TRACK
            // PASS WROTE IT THIS FRAME (`trackPosedThisFrame`); that pass bails
            // out when there is no clock, and reading it then would be the
            // PREVIOUS frame's composed pose.
            let resolvedBase: Transform
            if trackPosedThisFrame.contains(name) {
                resolvedBase = entity.transform
            } else if let pose = actionPoses[name] {
                resolvedBase = pose
            } else if let rest = authoredRestTransform(for: name) {
                // The Sequence-local placement when there is one: a behavior on
                // a locally-staged object used to compose onto the
                // CHAPTER-global pose, so it entered from the wrong place.
                resolvedBase = rest
            } else {
                continue
            }

            var combined = ChapterScript.MotionOffset.identity
            var fades = false
            for (behavior, startedAt) in entries {
                let progress: Float
                if let startedAt, let authoredNow {
                    // AN AMBIENT BEHAVIOR IS NOT A RAMP: it is handed ELAPSED
                    // CYCLES, and the resolver takes the phase modulo one and
                    // returns identity once the authored span has run out.
                    progress = MotionCurveSampling.behaviorProgress(
                        behavior, startTime: startedAt, now: authoredNow)
                } else {
                    // With no authored clock an ambient behavior sits at its
                    // authored pose rather than at some arbitrary point in a
                    // cycle it cannot measure.
                    progress = behavior.kind == .ambient ? 0 : 1
                }
                if MotionCurveSampling.animatesOpacity(behavior) { fades = true }
                combined = ChapterScript.MotionOffset.combine(
                    combined,
                    ChapterScript.MotionBehaviorResolver.offset(
                        behavior, progress: progress, viewerYaw: viewerYaw,
                        restPosition: resolvedBase.translation)
                )
            }

            // The opacity the multiplier goes onto, read only when a behavior
            // fades. Captured from the entity ONCE, before this layer first
            // writes it, so later frames never read their own output back.
            var baseOpacity: Float = 1
            if fades {
                if let keyed = trackOpacitiesThisFrame[name] {
                    baseOpacity = keyed
                } else if let authored = actionOpacities[name] {
                    baseOpacity = authored
                } else {
                    baseOpacity = entity.opacity
                    actionOpacities[name] = baseOpacity
                }
            }

            let drawn = MotionCurveSampling.composing(
                combined,
                onto: (resolvedBase.translation, resolvedBase.rotation, resolvedBase.scale),
                opacity: baseOpacity)
            entity.position = drawn.position
            entity.scale = drawn.scale
            entity.orientation = drawn.rotation
            if fades {
                if drawn.opacity < 0.999 {
                    entity.components.set(OpacityComponent(opacity: drawn.opacity))
                } else if entity.components.has(OpacityComponent.self) {
                    entity.components.remove(OpacityComponent.self)
                }
            }
        }
    }

    public func applyActiveMotions(segmentElapsed: TimeInterval, totalElapsed: TimeInterval) {
        // THE EDITORS' ORDER (`ScrubCompositor`, the Mac compositor): timed
        // actions and a legacy `animateMotion`, then the tracks that override
        // them, then the motion layer on top of whatever those produced.
        applyActionTweens()
        applyLegacyMotions(segmentElapsed: segmentElapsed, totalElapsed: totalElapsed)
        applySequenceAnimationTracks()
        applyActiveBehaviors()
    }

    /// A LEGACY `animateMotion`, written as part of the ACTION layer: before
    /// the tracks and the behaviors, as the editors fold it in with the other
    /// timed actions. It used to run LAST, so it overwrote both, and a Float
    /// on an Object with an `animateMotion` did nothing on the headset while
    /// the editors drew it.
    ///
    /// It writes only the channels it authors (`legacyMotionSample`), onto
    /// the action pose, never onto the rendered one. A Move, Scale or placing
    /// Reveal that fired AFTER it on the same Object wins, as a later action
    /// does in the editors' time walk.
    private func applyLegacyMotions(segmentElapsed: TimeInterval, totalElapsed: TimeInterval) {
        guard !activeMotions.isEmpty else { return }
        let authoredNow = animationClock?()
        // Sequence seconds on the authored clock, as the editors pass it
        // (oscillate's phase); the engine's elapsed time only without one.
        let absoluteTime = Float(authoredNow ?? totalElapsed)
        for (action, startedAt, serial) in activeMotions.values {
            guard let entity = entityRegistry[action.entity] else { continue }
            if let later = transformActionSerials[action.entity], later > serial { continue }
            // Measured from the MOTION's own start on the authored clock — the
            // same rule `ScrubCompositor` uses, so the editor and the headset
            // draw the same frame. Falls back to the legacy segment-relative
            // measure only when no authored clock was available.
            let progress: Float
            if let startedAt, let authoredNow {
                progress = MotionProgress.progress(startTime: startedAt,
                                                   now: authoredNow,
                                                   duration: action.duration)
            } else {
                progress = MotionProgress.progress(startTime: 0,
                                                   now: segmentElapsed,
                                                   duration: action.duration)
            }
            let sample = MotionCurveSampling.legacyMotionSample(
                position: action.position, rotation: action.rotation, scale: action.scale,
                progress: progress, absoluteTime: absoluteTime)
            if sample.isEmpty { continue }
            var pose = actionPose(for: action.entity, entity)
            if let position = sample.position { pose.translation = position }
            if let rotation = sample.rotation { pose.rotation = rotation }
            if let scale = sample.scale { pose.scale = scale }
            entity.transform = pose
            actionPoses[action.entity] = pose
        }
    }

    /// Which Objects the track pass posed THIS frame, and the opacity it
    /// wrote for those whose track keys opacity: the motion layer's base.
    /// Rebuilt every frame, kept for its capacity.
    private var trackPosedThisFrame: Set<String> = []
    private var trackOpacitiesThisFrame: [String: Float] = [:]

    /// Sample every sequence track at the authored sequence time and write the
    /// poses. Runs even for disabled entities so a reveal mid-curve finds
    /// the entity already in the right pose. Opacity is only driven when the
    /// track keys it — otherwise the segment/action system owns visibility.
    /// EXPLORE LOOP OVERLAY, by authored entity id.
    ///
    /// Set only for the few entities an author explicitly marked "Loop During
    /// Explore", and only while the story is held at a region boundary. The
    /// ordinary Sequence clock stays PARKED at that boundary — this replaces
    /// the sample time for these entities alone. It moves no key, rewrites no
    /// track and creates no second animation system; when the region resolves
    /// the override is removed and evaluation returns to normal.
    public var animationLoopOverrides: [String: Double] = [:]

    private func applySequenceAnimationTracks() {
        trackPosedThisFrame.removeAll(keepingCapacity: true)
        trackOpacitiesThisFrame.removeAll(keepingCapacity: true)
        guard !sequenceAnimationTracks.isEmpty, let clock = animationClock else { return }
        let time = clock()
        for track in sequenceAnimationTracks {
            guard let entity = entityRegistry[track.entity] else { continue }
            // The overlay wins for this entity, if one is installed.
            let time = animationLoopOverrides[track.entity] ?? time
            // NO AUTHORED REST ⇒ NO SAMPLE. Evaluating against a fabricated
            // rest writes the unkeyed channels somewhere nobody authored.
            guard let rest = authoredRest(for: track.entity) else { continue }
            let pose = SequenceAnimationEvaluator.samplePose(track, at: time, rest: rest)
            entity.position = SIMD3(pose.position.x, pose.position.y, pose.position.z)
            entity.orientation = simd_quatf(
                vector: SIMD4(pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w)
            )
            entity.scale = SIMD3(pose.scale.x, pose.scale.y, pose.scale.z)
            trackPosedThisFrame.insert(track.entity)
            if let opacity = pose.opacity {
                entity.components.set(OpacityComponent(opacity: opacity))
                trackOpacitiesThisFrame[track.entity] = opacity
            }
        }
    }

    /// SEQUENCE-LOCAL REST OVERRIDES, installed at sequence entry from
    /// `SequenceDefinition.restPlacements`. An entry replaces the
    /// Chapter rest for animation's unkeyed-channel fallback while its
    /// sequence plays; `applyRestPlacements` swaps the set atomically on
    /// every entry so a placement can never leak into the next sequence.
    private var sequenceRestOverrides: [String: TransformData] = [:]

    /// Install a sequence's local rest placements: entities placed by
    /// the PREVIOUS sequence and not by this one return to their
    /// Chapter rest, placed entities move to their local rest, and the
    /// animation fallback follows. Idempotent per sequence entry.
    public func applyRestPlacements(_ placements: [String: TransformData]) {
        // Restore anything the outgoing sequence had placed.
        for name in sequenceRestOverrides.keys where placements[name] == nil {
            if let original = originalTransforms[name], let entity = entityRegistry[name] {
                entity.transform = original
                actionPoses.removeValue(forKey: name)
            }
        }
        sequenceRestOverrides = placements
        for (name, data) in placements {
            guard let entity = entityRegistry[name] else { continue }
            actionPoses.removeValue(forKey: name)
            entity.transform = Transform(
                scale: SIMD3(data.scale.x, data.scale.y, data.scale.z),
                rotation: simd_quatf(vector: SIMD4(
                    data.rotation.x, data.rotation.y, data.rotation.z, data.rotation.w
                )),
                translation: SIMD3(data.position.x, data.position.y, data.position.z)
            )
        }
    }

    /// One placement, edited while its Sequence is current. An editor host
    /// moves the entity itself; this keeps the BASELINE in sync, so a reset
    /// that does not pass through a fresh Sequence entry returns the object to
    /// where it was just put rather than to the placement it had at entry.
    /// `nil` clears the placement (the Chapter rest applies again).
    public func setRestPlacement(_ placement: TransformData?, for name: String) {
        sequenceRestOverrides[name] = placement
        // The host moved the Object itself: the action layer starts again
        // from the new placement rather than pulling it back.
        actionPoses.removeValue(forKey: name)
    }

    /// THE AUTHORED REST — this Sequence's local placement when it has one,
    /// else the registration-time transform (the Chapter-global rest).
    ///
    /// OPTIONAL, AND THAT IS THE POINT. Both readers used to end
    /// `?? entity.transform`, which makes the RENDERED pose the authored one
    /// the moment an entity is in the registry without a registration snapshot
    /// — and a rendered pose is animation, motion offsets and effects already
    /// composed in. Folding that back in as "rest" is how an object walks away
    /// from where it was authored, a frame at a time, with the document saying
    /// something else the whole way. Authored state flows to rendered state and
    /// never back. If there is no authored rest for a name, this executor does
    /// not know where that object belongs and must not invent an answer from
    /// the screen.
    ///
    /// (The gap it papered over was real: a host that puts an entity straight
    /// into `entityRegistry` instead of calling `register(_:name:)` gets no
    /// snapshot. That is fixed at the host — see MaestroVision's placeholder
    /// proxies — so this returning nil now means a genuine bug, and says so.)
    private func authoredRest(for name: String) -> TransformData? {
        if let local = sequenceRestOverrides[name] { return local }
        guard let t = originalTransforms[name] else {
            logger.warning("no authored rest for '\(name)' — it was never registered; leaving its pose alone")
            return nil
        }
        return TransformData(
            position: Vec3(t.translation.x, t.translation.y, t.translation.z),
            rotation: Quat(
                x: t.rotation.vector.x, y: t.rotation.vector.y,
                z: t.rotation.vector.z, w: t.rotation.vector.w
            ),
            scale: Vec3(t.scale.x, t.scale.y, t.scale.z)
        )
    }

    /// The same answer as a RealityKit `Transform`.
    private func authoredRestTransform(for name: String) -> Transform? {
        guard let data = authoredRest(for: name) else { return nil }
        return Transform(
            scale: SIMD3(data.scale.x, data.scale.y, data.scale.z),
            rotation: simd_quatf(vector: SIMD4(
                data.rotation.x, data.rotation.y, data.rotation.z, data.rotation.w
            )),
            translation: SIMD3(data.position.x, data.position.y, data.position.z)
        )
    }

    // MARK: - Entity Persistence

    public func persistEntity(named name: String) {
        persistedEntityNames.insert(name)
        logger.info("Persist entity: \(name)")
    }

    public func unpersistEntity(named name: String) {
        persistedEntityNames.remove(name)
        logger.info("Unpersist entity: \(name)")
    }

    public func enableGesture(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("enableGesture: '\(name)' not found in registry")
            return
        }
        if entity.components[InputTargetComponent.self] == nil {
            entity.components.set(InputTargetComponent())
        }
        if entity.components[HoverEffectComponent.self] == nil {
            entity.components.set(HoverEffectComponent(
                .spotlight(HoverEffectComponent.SpotlightHoverEffectStyle(
                    strength: 2.3
                ))
            ))
        }
        logger.debug("Enabled gesture: \(name)")
    }

    public func disableGesture(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("disableGesture: '\(name)' not found in registry")
            return
        }
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(HoverEffectComponent.self)
        logger.debug("Disabled gesture: \(name)")
    }
}
