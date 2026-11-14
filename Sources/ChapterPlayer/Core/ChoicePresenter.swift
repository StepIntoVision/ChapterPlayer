//
//  ChoicePresenter.swift
//  ChapterPlayer
//
//  THE VIEWER-FACING CHOICE, DRAWN ON THE HEADSET (OD-8).
//
//  Owner rule: a Choice is the moment the viewer decides; a Path is where an
//  option leads; the Memory kind `.choice` keeps recording WHAT was chosen.
//  While the story waits at a Cue that carries a Choice
//  (`SegmentGateDTO.choice`, `GateActivation.waitsForChoice`), this shows the
//  Cue's question and one button per option near the viewer (near the Cue's
//  Object, or in front of the viewer when the Cue names none), and goes away
//  the moment the Cue is answered, stopped or seeked past.
//
//  WHAT A PICK DOES IS NOT DECIDED HERE. A tap or a look-and-pinch on a
//  button arrives through the one tap route (`InteractionController
//  .handleTap(on:)` -> the gate offer in `ChapterPlayerCore`), which reads the
//  option back with `optionId(forEntityName:)` and hands it to
//  `ChapterPlayerCore.pickChoiceOption(_:)`. That applies the pure
//  resolution (`GateActivation.pick`): Memory first, then the option's Path
//  through the one navigator. A VoiceOver Activate on a button takes the
//  same route through `onPick`.
//
//  THE LOOK. Each button wears the Cue Prompt's caption recipe
//  (`CuePromptPresenter.style`): white type on a dark rounded plate,
//  billboarded with the question, sized by visual angle. The buttons
//  highlight where the viewer looks (`HoverEffectComponent`, the system's own hover), which is how a
//  visionOS control says "this one".
//
//  ACCESS. Every button is an accessibility element whose label is the
//  option's words (the same words on the plate,
//  `GateActivation.accessibleChoiceLabels`), and the question and options are
//  announced once when they appear.
//

import Foundation
import ChapterScript

/// WHAT TO DRAW for one waiting Choice Cue. Pure, so the rule is testable
/// without a scene.
public struct ChoicePlan: Sendable, Equatable {

    public struct Option: Sendable, Equatable {
        public let optionId: String
        /// The words on the button, never empty (`CueChoice.displayLabel`).
        public let label: String
        /// The scene Object acting on which also picks this option, if any.
        public let targetEntity: String?
    }

    /// The Cue's Prompt, trimmed: the question. Nil when the author wrote none.
    public let question: String?
    /// The options drawn as buttons, in authored order.
    public let buttons: [Option]
    /// Every option, in authored order, including the ones picked only by
    /// acting on their Object (`.objects` style).
    public let options: [Option]
    public let placement: CuePromptPlan.Placement

    /// What assistive technology reads when the Choice appears: the
    /// question, then each option, in authored order.
    public var announcement: String {
        let list = options.map(\.label).joined(separator: ", ")
        guard let question else { return list }
        return "\(question) \(list)"
    }

    /// The plan for a Cue that has begun waiting, or nil when it carries no
    /// Choice. `definitions` are the Chapter's Memory, read only for the
    /// recorded option's name when an option has no label of its own.
    public static func plan(for gate: SegmentGateDTO,
                            definitions: [StoryStateDefinition] = []) -> ChoicePlan? {
        guard GateActivation.waitsForChoice(gate), let choice = gate.choice else { return nil }
        let definition = choice.stateId.flatMap { id in definitions.first { $0.id == id } }
        let options = choice.options.map { option in
            Option(optionId: option.optionId,
                   label: choice.displayLabel(for: option, definition: definition),
                   targetEntity: option.targetEntity)
        }
        // `.panel` draws every option. `.objects` draws only the options that
        // name no Object, so every option can always be picked.
        let buttons: [Option]
        switch choice.resolvedStyle {
        case .panel:   buttons = options
        case .objects: buttons = options.filter { $0.targetEntity == nil }
        }
        let trimmed = gate.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let placement: CuePromptPlan.Placement
        if let target = gate.targetEntity, !target.isEmpty {
            placement = .nearObject(target)
        } else {
            placement = .inFrontOfViewer
        }
        return ChoicePlan(question: question, buttons: buttons, options: options,
                          placement: placement)
    }

    // MARK: Naming the buttons

    /// The prefix every button entity's name carries. Names are by POSITION,
    /// never by option id: an id is opaque authored data and the name is how
    /// a tap is read back (`optionId(forEntityName:)`).
    public static let buttonNamePrefix = "cue.choice.option."

    public static func buttonName(at index: Int) -> String {
        "\(buttonNamePrefix)\(index)"
    }

    /// The option a button's entity name stands for, or nil when the name
    /// is not one of this plan's buttons.
    public func optionId(forEntityName name: String?) -> String? {
        guard let name, name.hasPrefix(Self.buttonNamePrefix),
              let index = Int(name.dropFirst(Self.buttonNamePrefix.count)),
              buttons.indices.contains(index) else { return nil }
        return buttons[index].optionId
    }
}

#if canImport(RealityKit)
import Combine
import RealityKit
import simd
import UIKit

/// Puts one `ChoicePlan` in the scene, and takes it away.
@MainActor
public final class ChoicePresenter {

    /// The scene the Choice is drawn in (the head-rebased scene root).
    public var sceneRootProvider: (() -> Entity?)?
    /// Resolves a Cue's Object by its authored name.
    public var entityProvider: ((String) -> Entity?)?
    /// A button was activated by assistive technology. The player routes it
    /// to the same pick a tap makes.
    public var onPick: ((String) -> Void)?

    /// The plan on show, if any. Recorded even with no scene to draw in (a
    /// windowed host, a test), so the pick route still reads it.
    public private(set) var shown: ChoicePlan?
    /// The mounted panel, if any.
    public private(set) var panelEntity: Entity?

    private var accessibilitySubscription: (any Cancellable)?

    /// Space between two buttons, in meters.
    public static let buttonGap: Float = 0.015

    public init() {}

    /// The option a tapped entity's name stands for, while a Choice is up.
    public func optionId(forEntityName name: String?) -> String? {
        shown?.optionId(forEntityName: name)
    }

    /// Show `plan`, replacing whatever was shown. Nil hides.
    public func show(_ plan: ChoicePlan?) {
        hide()
        guard let plan else { return }
        shown = plan
        guard let root = sceneRootProvider?() else { return }

        let object = CuePromptPresenter.object(for: plan.placement, resolving: entityProvider)
        let position = CuePromptPresenter.position(for: plan.placement, in: root, object: object)
        let capHeight = CuePromptPlan.capHeight(atDistance: simd_length(position))
        let panel = Self.makePanel(plan, capHeight: capHeight)
        panel.position = position
        root.addChild(panel)
        panelEntity = panel

        if let scene = root.scene {
            accessibilitySubscription = scene.subscribe(to: AccessibilityEvents.Activate.self) { [weak self] event in
                Task { @MainActor in
                    guard let self,
                          let optionId = self.optionId(forEntityName: Self.buttonName(containing: event.entity))
                    else { return }
                    self.onPick?(optionId)
                }
            }
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: plan.announcement)
        }
    }

    /// Take the Choice away. Idempotent.
    public func hide() {
        accessibilitySubscription?.cancel()
        accessibilitySubscription = nil
        panelEntity?.removeFromParent()
        panelEntity = nil
        shown = nil
    }

    /// The nearest ancestor (or self) named as a button.
    static func buttonName(containing entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            if current.name.hasPrefix(ChoicePlan.buttonNamePrefix) { return current.name }
            node = current.parent
        }
        return nil
    }

    // MARK: - The look

    /// The question on top, the buttons stacked under it, billboarded as one.
    static func makePanel(_ plan: ChoicePlan, capHeight: Float) -> Entity {
        let panel = Entity()
        panel.name = "cue.choice"
        panel.components.set(BillboardComponent())
        let style = CuePromptPresenter.style(capHeight: capHeight)

        var y: Float = 0
        if let question = plan.question,
           let built = try? CaptionBlock.build(text: question, style: style) {
            let block = CaptionBlock.makeBlock(built, name: "cue.choice.question")
            var accessibility = AccessibilityComponent()
            accessibility.isAccessibilityElement = true
            accessibility.label = LocalizedStringResource(stringLiteral: question)
            block.components.set(accessibility)
            panel.addChild(block)
            y -= CaptionBlock.stackAdvance(built) + buttonGap
        }
        for (index, option) in plan.buttons.enumerated() {
            guard let built = try? CaptionBlock.build(text: option.label, style: style) else { continue }
            let button = makeButton(built, label: option.label, name: ChoicePlan.buttonName(at: index))
            button.position = SIMD3<Float>(0, y, 0)
            panel.addChild(button)
            y -= CaptionBlock.stackAdvance(built) + buttonGap
        }
        return panel
    }

    /// One option: the caption block, hit-testable over its whole plate,
    /// highlighted by the system's hover where the viewer looks, and an accessibility element.
    static func makeButton(_ built: CaptionBlock.Result, label: String, name: String) -> Entity {
        let button = CaptionBlock.makeBlock(built, name: name)
        // EVERY PART CARRIES THE BUTTON'S NAME, so a tap that lands on the
        // words or the plate reads back as this option whichever part the
        // hit test returns.
        for child in button.children { child.name = name }
        let width = built.textSize.x + CaptionBlock.platePadding * 2
        let height = built.textSize.y + CaptionBlock.platePadding * 2
        button.components.set(CollisionComponent(shapes: [
            .generateBox(size: SIMD3<Float>(max(width, 0.02), max(height, 0.02), 0.01))
        ]))
        button.components.set(InputTargetComponent())
        button.components.set(HoverEffectComponent())
        var accessibility = AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = LocalizedStringResource(stringLiteral: label)
        button.components.set(accessibility)
        return button
    }
}
#endif
