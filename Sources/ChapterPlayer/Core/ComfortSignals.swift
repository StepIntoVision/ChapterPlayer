//
//  ComfortSignals.swift
//  ChapterPlayer
//
//  WHAT THE SYSTEM IS TELLING US ABOUT COMFORT AND HEAT, AND WHAT THE STORY DOES.
//
//  Two signals the platform already sends and this runtime used to drop:
//
//    1. `VideoPlayerEvents.VideoComfortMitigationDidOccur` — a RealityKit
//       scene EVENT (visionOS 26+, not a notification), raised when the system
//       intervenes in immersive video for the viewer's comfort. It carries a
//       `VideoPlayerComponent.VideoComfortMitigation`: `.play`, `.pause` or
//       `.reduceImmersion`.
//    2. `ProcessInfo.thermalStateDidChangeNotification`.
//
//  THE RESPONSE (OD-50, owner decision). When the system pauses or shrinks
//  immersive video for the viewer's comfort, the WHOLE STORY pauses with it
//  and a short calm message says so; when the system resumes playback, the
//  story resumes with it. At very high heat (`.critical`) the viewer sees a
//  warning only: nothing pauses. The decision is pure
//  (`ComfortSignals.response(to:)`, `ComfortSignals.thermalWarning(for:)`);
//  `ChapterPlayerCore` carries it out through `onResponse`, pausing the
//  engine with the same `pause()`/`resume()` the transport uses. The message
//  is drawn by `ComfortNoticePresenter`, on the caption recipe. Every change
//  is still logged, so a device session can read it back out of the log.
//
//  The recording half is pure (`recordThermal`, `recordMitigation` take their
//  inputs as values), so it is tested without a scene and without heating a
//  device. Only `startObservingThermalState` and `observeVideoComfort(in:)`
//  touch the system.
//

import Combine
import Foundation
import OSLog
import RealityKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "ComfortSignals"
)

@MainActor
@Observable
public final class ComfortSignals {

    // MARK: - Values

    /// `ProcessInfo.ThermalState`, as a value this package owns: ordered, so
    /// "did it get worse" is a comparison, and `CaseIterable` for a host menu.
    public enum ThermalLevel: Int, Sendable, Comparable, CaseIterable {
        case nominal, fair, serious, critical

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal:  self = .nominal
            case .fair:     self = .fair
            case .serious:  self = .serious
            case .critical: self = .critical
            // A state a future OS adds is, by the platform's own ordering,
            // beyond critical. Reading it as nominal would hide the one
            // reading that matters most.
            @unknown default: self = .critical
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The platform's own word for it, for a host label or a log line.
        public var label: String {
            switch self {
            case .nominal:  return "Nominal"
            case .fair:     return "Fair"
            case .serious:  return "Serious"
            case .critical: return "Critical"
            }
        }

        /// Serious or worse: the system is already throttling.
        public var isConstrained: Bool { self >= .serious }
    }

    /// What the system did to immersive video for the viewer's comfort.
    public enum VideoMitigation: String, Sendable, Equatable, CaseIterable {
        case play
        case pause
        case reduceImmersion
        /// A mitigation a newer OS reports that this build has no name for.
        /// Counted and logged, never dropped.
        case unknown

        public var label: String {
            switch self {
            case .play:            return "Resumed playback"
            case .pause:           return "Paused playback"
            case .reduceImmersion: return "Reduced immersion"
            case .unknown:         return "Unrecognized mitigation"
            }
        }
    }

    // MARK: - The response (OD-50)

    /// What the player does about one comfort signal.
    public enum Response: Sendable, Equatable {
        /// Pause the whole story and show `message`.
        case pauseStory(message: String)
        /// The system resumed playback: resume a story this paused.
        case resumeStory
        /// Very high heat: show `message`, pause nothing.
        case showWarning(message: String)
        /// The heat came down: take the warning away.
        case clearWarning
    }

    /// The calm message shown while the story is paused for comfort. One
    /// sentence the viewer can read at a glance; it promises no timing,
    /// because the system decides when playback comes back.
    public static let comfortPauseMessage = "Paused for your comfort. The story will pick up where it left off."
    /// The warning shown at very high heat. A suggestion, never an order:
    /// the story keeps playing.
    public static let heatWarningMessage = "This device is very warm. You may want to take a short break."

    /// What a video comfort mitigation asks of the story. PURE.
    ///
    /// A pause or a reduced immersion pauses the story (OD-50: "pause the
    /// whole story with it"); the system resuming playback resumes it. A
    /// mitigation this build has no name for changes nothing: guessing a
    /// pause would stop a story for a reason nobody can see.
    public static func response(to mitigation: VideoMitigation) -> Response? {
        switch mitigation {
        case .pause, .reduceImmersion: return .pauseStory(message: comfortPauseMessage)
        case .play:                    return .resumeStory
        case .unknown:                 return nil
        }
    }

    /// The warning the viewer sees at `level`, or nil. Only `.critical` is
    /// "very high heat"; `.serious` is the system's own throttling and is
    /// logged, not shown.
    public static func thermalWarning(for level: ThermalLevel) -> String? {
        level >= .critical ? heatWarningMessage : nil
    }

    /// Carries a response out. Set by `ChapterPlayerCore`; called on the main
    /// actor, synchronously, as each signal is recorded.
    @ObservationIgnored public var onResponse: ((Response) -> Void)?

    /// The warning on show, if any (OD-50). For hosts and tests.
    public private(set) var activeWarning: String?

    // MARK: - Published state

    /// The latest thermal reading.
    public private(set) var thermalLevel: ThermalLevel = .nominal
    /// When `thermalLevel` last CHANGED. Nil until it has.
    public private(set) var thermalLevelChangedAt: Date?
    /// The worst reading since observation began or `reset()`.
    public private(set) var peakThermalLevel: ThermalLevel = .nominal

    /// How many comfort mitigations the system has applied this session.
    public private(set) var mitigationCount: Int = 0
    /// The most recent one, and when.
    public private(set) var lastMitigation: VideoMitigation?
    public private(set) var lastMitigationAt: Date?

    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var comfortSubscription: (any Cancellable)?
    @ObservationIgnored private weak var observedScene: RealityKit.Scene?

    public init() {}

    // MARK: - Recording (pure)

    /// Record a thermal reading. Returns true when the level CHANGED, which
    /// is the only time anything is published or logged — the notification
    /// can repeat a state, and republishing it would invalidate a host view
    /// for a label that reads the same.
    @discardableResult
    public func recordThermal(_ level: ThermalLevel, at date: Date = Date()) -> Bool {
        guard level != thermalLevel else { return false }
        let previous = thermalLevel
        thermalLevel = level
        thermalLevelChangedAt = date
        if level > peakThermalLevel { peakThermalLevel = level }
        if level.isConstrained {
            logger.warning("[comfort] thermal state \(previous.label, privacy: .public) -> \(level.label, privacy: .public)")
        } else {
            logger.info("[comfort] thermal state \(previous.label, privacy: .public) -> \(level.label, privacy: .public)")
        }
        // OD-50: very high heat shows a warning, and only a warning.
        let warning = Self.thermalWarning(for: level)
        if warning != activeWarning {
            activeWarning = warning
            onResponse?(warning.map { .showWarning(message: $0) } ?? .clearWarning)
        }
        return true
    }

    /// Record one comfort mitigation. Every one counts, including a repeat of
    /// the last: two pauses are two interventions.
    public func recordMitigation(_ mitigation: VideoMitigation, at date: Date = Date()) {
        mitigationCount += 1
        lastMitigation = mitigation
        lastMitigationAt = date
        logger.warning("[comfort] video comfort mitigation #\(self.mitigationCount): \(mitigation.label, privacy: .public)")
        if let response = Self.response(to: mitigation) { onResponse?(response) }
    }

    /// Forget the session's history. The current thermal level is a fact about
    /// the device, not the session, so it stays.
    public func reset() {
        mitigationCount = 0
        lastMitigation = nil
        lastMitigationAt = nil
        peakThermalLevel = thermalLevel
    }

    // MARK: - Observation

    /// Begin following the device's thermal state. Idempotent.
    public func startObservingThermalState() {
        guard thermalObserver == nil else { return }
        recordThermal(ThermalLevel(ProcessInfo.processInfo.thermalState))
        peakThermalLevel = thermalLevel
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordThermal(ThermalLevel(ProcessInfo.processInfo.thermalState))
            }
        }
    }

    /// Follow comfort mitigations raised in `scene`. Idempotent per scene, so
    /// it is safe to call every time a video component is attached.
    public func observeVideoComfort(in scene: RealityKit.Scene?) {
        guard let scene, scene !== observedScene else { return }
        comfortSubscription?.cancel()
        observedScene = scene
        comfortSubscription = scene.subscribe(
            to: VideoPlayerEvents.VideoComfortMitigationDidOccur.self
        ) { [weak self] event in
            let mitigation = VideoMitigation(event.comfortMitigation)
            Task { @MainActor [weak self] in
                self?.recordMitigation(mitigation)
            }
        }
        logger.info("[comfort] observing video comfort mitigations")
    }

    /// Stop observing. NOT in `deinit`: the observer is main-actor isolated
    /// and `deinit` is not. `ChapterPlayerCore` owns one for the app's
    /// lifetime, so in practice this is for hosts that discard a player.
    public func stopObserving() {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        thermalObserver = nil
        comfortSubscription?.cancel()
        comfortSubscription = nil
        observedScene = nil
    }
}

extension ComfortSignals.VideoMitigation {
    /// From the SDK's value. `@unknown default` rather than a plain default, so
    /// a case the SDK adds is a compiler warning here, not a silent `.unknown`.
    init(_ mitigation: VideoPlayerComponent.VideoComfortMitigation) {
        switch mitigation {
        case .play:            self = .play
        case .pause:           self = .pause
        case .reduceImmersion: self = .reduceImmersion
        @unknown default:      self = .unknown
        }
    }
}

// MARK: - The calm message (OD-50)

#if canImport(UIKit)
import UIKit

/// Draws the one comfort message (a pause notice or a heat warning) in front
/// of the viewer, on the caption recipe the Cue Prompt wears: white type on a
/// dark rounded plate, billboarded, sized by visual angle. Announced once to
/// VoiceOver when it appears. One message at a time; a new one replaces it.
@MainActor
public final class ComfortNoticePresenter {

    /// The scene the message is drawn in (the head-rebased scene root).
    public var sceneRootProvider: (() -> Entity?)?

    /// The message on show, if any. Recorded even with no scene (a windowed
    /// host, a test), so a host can still say it.
    public private(set) var shown: String?
    public private(set) var noticeEntity: Entity?

    /// How far ahead of the viewer the message sits, and how far below the
    /// line of sight: close enough to read, low enough not to cover the
    /// picture it is talking about.
    public static let viewerDistance: Float = 1.2

    public init() {}

    public func show(_ message: String?) {
        hide()
        guard let message, !message.isEmpty else { return }
        shown = message
        guard let root = sceneRootProvider?() else { return }
        let capHeight = CuePromptPlan.capHeight(atDistance: Self.viewerDistance)
        let container = Entity()
        container.name = "comfort.notice"
        container.components.set(BillboardComponent())
        var accessibility = AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = LocalizedStringResource(stringLiteral: message)
        container.components.set(accessibility)
        if let built = try? CaptionBlock.build(text: message,
                                               style: CuePromptPresenter.style(capHeight: capHeight)) {
            container.addChild(CaptionBlock.makeBlock(built, name: "comfort.notice.text"))
        }
        container.position = SIMD3<Float>(0, -0.12 * Self.viewerDistance, -Self.viewerDistance)
        root.addChild(container)
        noticeEntity = container
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    /// Take the message away. Idempotent.
    public func hide() {
        noticeEntity?.removeFromParent()
        noticeEntity = nil
        shown = nil
    }
}
#endif
