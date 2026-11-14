//
//  CuePromptPresenter.swift
//  ChapterPlayer
//
//  WHAT THE STORY IS WAITING FOR, DRAWN ON THE HEADSET (OD-38).
//
//  While the story waits at a Cue, the viewer sees the Cue's Prompt (the
//  sentence the author wrote, `SegmentGateDTO.prompt`) and a small waiting
//  sign, near the Cue's Object, or in front of the viewer when the Cue names
//  no Object. Both go away the moment the Cue is satisfied.
//
//  Event-driven, never polled: `GateDetectionController.onGateActivated`
//  shows it and `onGateResolved` hides it. The waiting sign's breathing is
//  one RealityKit animation, not a timer. Two things wait or watch, and only
//  while a Prompt is up:
//  · OD-122: a Memory or Orchestrator Cue with no Prompt shows its waiting
//    sign only after `unpromptedWaitSignDelay` (3 s); a shorter wait shows
//    nothing. One scheduled task, cancelled by `hide()`.
//  · TODO-99: a Prompt near an Object follows it while the Cue waits (one
//    scene-update subscription, cancelled by `hide()`), and a very large
//    Object gets its Prompt at its near side, near the eye line, rather than
//    over its far-off top.
//
//  COMFORT AND ACCESS:
//  · Billboarded, so it always faces the viewer.
//  · Sized by visual angle, so it reads the same near or far.
//  · On the caption recipe (`CaptionBlock`): white type on a dark rounded
//    plate, legible over any shot.
//  · An accessibility element whose label is the Prompt, announced once
//    when it appears. With Reduce Motion on, the sign holds still.
//

import Foundation
import ChapterScript

/// WHAT TO DRAW for one waiting Cue. Pure, so the rule is testable without
/// a scene.
public struct CuePromptPlan: Sendable, Equatable {

    public enum Placement: Sendable, Equatable {
        /// Above the named Object.
        case nearObject(String)
        /// Ahead of the viewer, a little below the line of sight.
        case inFrontOfViewer
    }

    /// The author's Prompt, trimmed. Nil when they wrote none: the waiting
    /// sign is then drawn on its own.
    public let prompt: String?
    public let placement: Placement
    /// Seconds the Cue waits before anything is drawn. Zero for every Cue
    /// but a Prompt-less Memory or Orchestrator Cue (OD-122).
    public let delay: TimeInterval

    /// What assistive technology reads for it.
    public var accessibilityLabel: String { prompt ?? "Waiting" }

    public init(prompt: String?, placement: Placement, delay: TimeInterval = 0) {
        self.prompt = prompt
        self.placement = placement
        self.delay = max(0, delay)
    }

    /// OD-122: how long a Memory or Orchestrator Cue with NO Prompt waits
    /// before its waiting sign shows. MIRRORS MaestroKit's
    /// `GateEditor.unpromptedWaitSignDelay`, which the Mac preview's banner
    /// reads (ChapterPlayer cannot import MaestroKit); a MaestroKit test reads
    /// this line to keep the two values equal.
    public static let unpromptedWaitSignDelay: TimeInterval = 3

    /// The plan for a Cue that has begun waiting, or nil when nothing is
    /// drawn.
    ///
    /// A Memory Cue (`.storyCondition`) waits for a fact, and an
    /// orchestrator Cue for a message from outside, not for the viewer. So
    /// without a Prompt a short wait draws nothing, and the waiting sign
    /// appears only once the wait runs long (OD-122): it says the story is
    /// waiting, never that the viewer should act. With a Prompt the author
    /// meant it to be read, and it is, at once.
    public static func plan(for gate: SegmentGate) -> CuePromptPlan? {
        let trimmed = gate.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let delay: TimeInterval = (prompt == nil && !viewerActs(gate.type))
            ? unpromptedWaitSignDelay : 0
        if let target = gate.targetEntity, !target.isEmpty {
            return CuePromptPlan(prompt: prompt, placement: .nearObject(target), delay: delay)
        }
        return CuePromptPlan(prompt: prompt, placement: .inFrontOfViewer, delay: delay)
    }

    /// Does this kind of Cue wait for the viewer to do something?
    /// EXHAUSTIVE with no `default`: a new Cue type must say.
    static func viewerActs(_ type: GateType) -> Bool {
        switch type {
        case .tap, .any, .viewerFacing, .proximity, .grab: return true
        case .orchestrator, .storyCondition: return false
        }
    }

    // MARK: Size

    /// Degrees of visual angle a capital letter subtends. A little smaller
    /// than a caption's (about 1.4 degrees at the default), because a Prompt
    /// is read while the viewer is looking at the Object, not instead of it.
    public static let capHeightDegrees: Float = 1.2

    /// Cap height in meters for a Prompt `distance` meters from the viewer,
    /// kept within a band so a very near Object does not shout and a very
    /// far one does not vanish.
    public static func capHeight(atDistance distance: Float) -> Float {
        let d = min(max(distance, 0.5), 8)
        let height = d * tan(capHeightDegrees * .pi / 180)
        return min(max(height, 0.018), 0.12)
    }

    /// How far ahead of the viewer an Object-less Prompt sits.
    public static let viewerDistance: Float = 1.4
    /// Clearance above an Object's top.
    public static let objectClearance: Float = 0.08

    // MARK: Placement near an Object (TODO-99)

    /// An Object wider, deeper or taller than this, in meters, is LARGE: a
    /// Prompt over its center top could sit far overhead, or inside it.
    public static let largeObjectSpan: Float = 1.5
    /// The highest a large Object's Prompt sits, in meters above the eye
    /// line (the scene root is rebased to the head, so the eye line is
    /// y = 0): a little above it, where it is read without craning.
    public static let largeObjectMaxRise: Float = 0.35

    /// Where the Prompt sits for an Object whose visual bounds, in the
    /// scene root's axes (the viewer at the origin, looking down -z), run
    /// from `boundsMin` to `boundsMax`. Pure, so the rule is testable
    /// without a scene.
    ///
    /// * An ordinary Object: centered, `objectClearance` above its top.
    /// * A large Object (`largeObjectSpan`): at the point of its footprint
    ///   nearest the viewer, pulled `objectClearance` toward them, and no
    ///   higher than `largeObjectMaxRise` above the eye line (lower when the
    ///   Object's top is lower). A viewer standing inside its footprint gets
    ///   the Prompt ahead of them at that height.
    public static func anchor(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) -> SIMD3<Float> {
        let size = boundsMax - boundsMin
        let center = (boundsMin + boundsMax) * 0.5
        let top = boundsMax.y + objectClearance
        let isLarge = max(size.x, max(size.y, size.z)) > largeObjectSpan
        guard isLarge else { return SIMD3<Float>(center.x, top, center.z) }

        let y = min(top, largeObjectMaxRise)
        // The footprint's point nearest the viewer (the origin).
        let nearX = min(max(Float(0), boundsMin.x), boundsMax.x)
        let nearZ = min(max(Float(0), boundsMin.z), boundsMax.z)
        let distance = (nearX * nearX + nearZ * nearZ).squareRoot()
        guard distance > 0.0001 else {
            // Inside the footprint: ahead of the viewer.
            return SIMD3<Float>(0, y, -viewerDistance)
        }
        let pulled = max(0, distance - objectClearance) / distance
        return SIMD3<Float>(nearX * pulled, y, nearZ * pulled)
    }
}

#if canImport(RealityKit)
import Combine
import RealityKit
import simd
import UIKit

/// Puts one `CuePromptPlan` in the scene, and takes it away.
@MainActor
public final class CuePromptPresenter {

    /// The scene the Prompt is drawn in. Its axes are the viewer's (the root
    /// is rebased to the head at Sequence start), which is what lets an
    /// Object-less Prompt sit "in front of the viewer".
    public var sceneRootProvider: (() -> Entity?)?
    /// Resolves a Cue's Object by its authored name.
    public var entityProvider: ((String) -> Entity?)?

    /// The plan on show, if any. For hosts and tests.
    public private(set) var shown: CuePromptPlan?
    /// A plan waiting out its `delay` (OD-122), not yet on show.
    public private(set) var pending: CuePromptPlan?
    /// The mounted Prompt, if any.
    public private(set) var promptEntity: Entity?

    /// The delayed show, cancelled by `hide()`.
    private var pendingTask: Task<Void, Never>?
    /// TODO-99: the Object the Prompt follows, and where the Prompt sits
    /// relative to it. Watched only while a Prompt is up.
    private var followedObject: Entity?
    private var followOffset = SIMD3<Float>(repeating: 0)
    private var followSubscription: (any Cancellable)?

    public init() {}

    /// Show `plan`, replacing whatever was shown. Nil hides. A plan with a
    /// `delay` waits that long first; a `hide()` (the Cue answered) or a new
    /// `show` in the meantime means it never appears.
    public func show(_ plan: CuePromptPlan?) {
        hide()
        guard let plan else { return }
        guard plan.delay > 0 else {
            mount(plan)
            return
        }
        pending = plan
        let nanoseconds = UInt64(plan.delay * 1_000_000_000)
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.pending == plan else { return }
            self.pending = nil
            self.pendingTask = nil
            self.mount(plan)
        }
    }

    /// Take the Prompt away, and any Prompt still waiting out its delay.
    /// Idempotent.
    public func hide() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        followSubscription?.cancel()
        followSubscription = nil
        followedObject = nil
        promptEntity?.removeFromParent()
        promptEntity = nil
        shown = nil
    }

    /// Draw `plan` now.
    private func mount(_ plan: CuePromptPlan) {
        // Recorded even with no scene to draw in (a windowed host, a test),
        // so a host can still say what the story is waiting for.
        shown = plan
        guard let root = sceneRootProvider?() else { return }

        let object = Self.object(for: plan.placement, resolving: entityProvider)
        let position = Self.position(for: plan.placement, in: root, object: object)
        let capHeight = CuePromptPlan.capHeight(atDistance: simd_length(position))
        let entity = Self.makePrompt(plan, capHeight: capHeight)
        entity.position = position
        root.addChild(entity)
        promptEntity = entity
        follow(object, from: position, in: root)

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: plan.accessibilityLabel)
        }
    }

    // MARK: - Following a moving Object (TODO-99)

    /// Keep the Prompt where it was put relative to `object` while the Cue
    /// waits: an Object that moves (an animation, a grab) takes its Prompt
    /// with it. One scene-update subscription, only while a Prompt is up.
    private func follow(_ object: Entity?, from position: SIMD3<Float>, in root: Entity) {
        guard let object, let scene = root.scene else { return }
        followedObject = object
        followOffset = position - object.position(relativeTo: root)
        followSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.followTick() }
        }
    }

    private func followTick() {
        guard let object = followedObject, let prompt = promptEntity,
              let root = prompt.parent, object.scene != nil else { return }
        let target = object.position(relativeTo: root) + followOffset
        // Moved by less than half a centimeter: leave it, so a still Object
        // costs one read per frame and no write.
        if simd_length(target - prompt.position) > 0.005 {
            prompt.position = target
        }
    }

    // MARK: - Placement

    static func object(for placement: CuePromptPlan.Placement,
                       resolving entityProvider: ((String) -> Entity?)?) -> Entity? {
        guard case .nearObject(let name) = placement else { return nil }
        return entityProvider?(name)
    }

    static func position(for placement: CuePromptPlan.Placement, in root: Entity,
                         resolving entityProvider: ((String) -> Entity?)?) -> SIMD3<Float> {
        position(for: placement, in: root, object: object(for: placement, resolving: entityProvider))
    }

    static func position(for placement: CuePromptPlan.Placement, in root: Entity,
                         object: Entity?) -> SIMD3<Float> {
        let ahead = SIMD3<Float>(0, -0.18 * CuePromptPlan.viewerDistance,
                                 -CuePromptPlan.viewerDistance)
        guard let object else { return ahead }
        let bounds = object.visualBounds(relativeTo: root)
        if bounds.isEmpty {
            return object.position(relativeTo: root)
                + SIMD3<Float>(0, CuePromptPlan.objectClearance * 3, 0)
        }
        // TODO-99: a very large Object is not crowned from its far-off top.
        return CuePromptPlan.anchor(boundsMin: bounds.min, boundsMax: bounds.max)
    }

    // MARK: - The look

    /// The Prompt on the caption recipe, with the waiting sign under it.
    static func makePrompt(_ plan: CuePromptPlan, capHeight: Float) -> Entity {
        let container = Entity()
        container.name = "cue.prompt"
        container.components.set(BillboardComponent())

        var accessibility = AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = LocalizedStringResource(stringLiteral: plan.accessibilityLabel)
        container.components.set(accessibility)

        var signY: Float = 0
        if let prompt = plan.prompt,
           let built = try? CaptionBlock.build(text: prompt, style: style(capHeight: capHeight)) {
            let block = CaptionBlock.makeBlock(built, name: "cue.prompt.text")
            container.addChild(block)
            signY = -(built.textSize.y / 2 + CaptionBlock.platePadding + capHeight * 0.9)
        }

        let sign = makeWaitingSign(capHeight: capHeight)
        sign.position = SIMD3<Float>(0, signY, 0)
        container.addChild(sign)
        return container
    }

    /// The caption style a Prompt wears: white on the dark caption plate,
    /// at most three lines.
    static func style(capHeight: Float) -> CaptionStyle {
        CaptionStyle(id: "cue_prompt", name: "Cue Prompt",
                     fontSize: capHeight,
                     color: ColorRGBA(r: 1, g: 1, b: 1, a: 1),
                     backgroundColor: ColorRGBA(r: 0, g: 0, b: 0, a: 0.6),
                     maxLineCount: 3,
                     maxWidth: capHeight * 18)
    }

    /// Three small dots on a dark pill, breathing slowly. Still when the
    /// viewer has asked for Reduce Motion.
    static func makeWaitingSign(capHeight: Float) -> Entity {
        let sign = Entity()
        sign.name = "cue.prompt.waiting"
        let radius = max(capHeight * 0.16, 0.003)
        let spacing = radius * 3.2

        let pill = ModelEntity(
            mesh: .generatePlane(width: spacing * 3, height: radius * 4,
                                 cornerRadius: radius * 2),
            materials: [CaptionBlock.unlit(ColorRGBA(r: 0, g: 0, b: 0, a: 1), opacity: 0.6)])
        pill.name = "cue.prompt.waiting.plate"
        pill.position.z = -CaptionBlock.plateOffset
        sign.addChild(pill)

        let dots = Entity()
        dots.name = "cue.prompt.waiting.dots"
        let dotMesh = MeshResource.generateSphere(radius: radius)
        let dotMaterial = CaptionBlock.unlit(ColorRGBA(r: 1, g: 1, b: 1, a: 1))
        for index in 0..<3 {
            let dot = ModelEntity(mesh: dotMesh, materials: [dotMaterial])
            dot.position = SIMD3<Float>(Float(index - 1) * spacing, 0, 0)
            dots.addChild(dot)
        }
        sign.addChild(dots)

        if !UIAccessibility.isReduceMotionEnabled {
            dots.components.set(OpacityComponent(opacity: 1))
            let breathe = FromToByAnimation(
                from: Float(1.0),
                to: Float(0.35),
                duration: 0.9,
                timing: .easeInOut,
                bindTarget: .opacity,
                repeatMode: .autoReverse)
            if let resource = try? AnimationResource.generate(with: breathe) {
                dots.playAnimation(resource.repeat())
            }
        }
        return sign
    }
}
#endif
