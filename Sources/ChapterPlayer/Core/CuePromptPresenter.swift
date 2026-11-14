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
//  shows it and `onGateResolved` hides it, so nothing here runs per frame.
//  The waiting sign's breathing is one RealityKit animation, not a timer.
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

    /// What assistive technology reads for it.
    public var accessibilityLabel: String { prompt ?? "Waiting" }

    public init(prompt: String?, placement: Placement) {
        self.prompt = prompt
        self.placement = placement
    }

    /// The plan for a Cue that has begun waiting, or nil when nothing is
    /// drawn.
    ///
    /// A Memory Cue (`.storyCondition`) waits for a fact, and an
    /// orchestrator Cue for a message from outside, not for the viewer. So
    /// without a Prompt they draw nothing: a waiting sign would ask for an
    /// act the viewer cannot perform. With a Prompt the author meant it to
    /// be read, and it is.
    public static func plan(for gate: SegmentGate) -> CuePromptPlan? {
        let trimmed = gate.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if prompt == nil, !viewerActs(gate.type) { return nil }
        if let target = gate.targetEntity, !target.isEmpty {
            return CuePromptPlan(prompt: prompt, placement: .nearObject(target))
        }
        return CuePromptPlan(prompt: prompt, placement: .inFrontOfViewer)
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
}

#if canImport(RealityKit)
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
    /// The mounted Prompt, if any.
    public private(set) var promptEntity: Entity?

    public init() {}

    /// Show `plan`, replacing whatever was shown. Nil hides.
    public func show(_ plan: CuePromptPlan?) {
        hide()
        guard let plan else { return }
        // Recorded even with no scene to draw in (a windowed host, a test),
        // so a host can still say what the story is waiting for.
        shown = plan
        guard let root = sceneRootProvider?() else { return }

        let position = Self.position(for: plan.placement, in: root,
                                     resolving: entityProvider)
        let capHeight = CuePromptPlan.capHeight(atDistance: simd_length(position))
        let entity = Self.makePrompt(plan, capHeight: capHeight)
        entity.position = position
        root.addChild(entity)
        promptEntity = entity

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: plan.accessibilityLabel)
        }
    }

    /// Take the Prompt away. Idempotent.
    public func hide() {
        promptEntity?.removeFromParent()
        promptEntity = nil
        shown = nil
    }

    // MARK: - Placement

    static func position(for placement: CuePromptPlan.Placement, in root: Entity,
                         resolving entityProvider: ((String) -> Entity?)?) -> SIMD3<Float> {
        let ahead = SIMD3<Float>(0, -0.18 * CuePromptPlan.viewerDistance,
                                 -CuePromptPlan.viewerDistance)
        guard case .nearObject(let name) = placement,
              let object = entityProvider?(name) else { return ahead }
        let bounds = object.visualBounds(relativeTo: root)
        if bounds.isEmpty {
            return object.position(relativeTo: root)
                + SIMD3<Float>(0, CuePromptPlan.objectClearance * 3, 0)
        }
        return SIMD3<Float>(bounds.center.x,
                            bounds.max.y + CuePromptPlan.objectClearance,
                            bounds.center.z)
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
