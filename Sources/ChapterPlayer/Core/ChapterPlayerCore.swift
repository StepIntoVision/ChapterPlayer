//
//  ChapterPlayerCore.swift
//  ChapterPlayer
//
//  Central observable state for a ChapterPlayer-driven visionOS app.
//  Owns the SequenceEngine, SpatialAudioManager, VideoPlaybackManager,
//  AssetPreloader, and all the pluggable executors. Wires them together
//  and exposes a small surface for the consuming app: `playSequence`,
//  `stopSequence`, `transitionToPhase`, and the live-experience hooks.
//
//  A consuming app typically aliases this type as `AppModel` and observes
//  it via `@Environment(AppModel.self)`. Customize the open/dismiss
//  ImmersiveSpace closures from a SwiftUI `.task` (`Environment(\.open
//  ImmersiveSpace)` / `\.dismissImmersiveSpace` are only available
//  inside a `View`). Optionally pass a non-default `immersiveSpaceID`
//  to the initializer when the consumer's scene declares a different
//  id than the package default.
//

import Foundation
import RealityKit
import SwiftUI
import OSLog
import ChapterScript
import ARKit
import CoreMedia

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "ChapterPlayerCore"
)

@MainActor private var _lastVideoBackdropSignatureStore: String?

/// WHICH ENGINE NAVIGATION THIS CODE IS RUNNING FOR (OD-111). Set for the
/// whole of an engine-raised navigation's Task (an authored Go To, a Sequence
/// ending, a story decision re-check, a Choice's Path), and nil for a host's
/// own call. That is how `navigate`, `performCompletion` and the performer
/// tell the engine's request from the person's without a second entry point.
private enum EngineNavigationContext {
    @TaskLocal static var token: Int?
}

@MainActor
@Observable
open class ChapterPlayerCore {

    // MARK: - Managers

    public let sequenceEngine = SequenceEngine()
    public let audioManager = SpatialAudioManager()
    public let videoManager = VideoPlaybackManager()
    public let assetPreloader = AssetPreloader()

    // MARK: - Executors

    public let entityExecutor = EntityActionExecutor()
    public let audioExecutor: AudioActionExecutor
    public let videoExecutor: VideoActionExecutor
    public let attachmentExecutor = AttachmentActionExecutor()
    public let effectExecutor = EffectActionExecutor()

    /// ONE sensing layer for "look at it", "walk up to it" and "grab it".
    /// Shared by gates and entity interactions — two detectors polling the same
    /// head pose would be two answers to one question, and twice the device QA.
    public let spatialTriggers = SpatialTriggerDetector()

    /// Runtime detection for the spatial gate types (viewer-facing / proximity
    /// / grab). Tap/orchestrator gates stay consumer-wired to `satisfyGate()`.
    public let gateDetection: GateDetectionController

    /// Live entity interactions: registration, lifetime, response dispatch and
    /// the accessible hover affordance. See `InteractionController`.
    public let interactions: InteractionController

    /// EXPLORE regions: the two clocks, the fallback timer and the
    /// continuation behaviors. See `StoryRegionController`.
    public let storyRegions = StoryRegionController()

    /// THE CUE'S PROMPT, DRAWN WHILE THE STORY WAITS (OD-38). Shown and
    /// hidden by the gate's own activation events. See `CuePromptPresenter`.
    public let cuePrompts = CuePromptPresenter()

    /// A "Continue by the Story" ending that found no match, holding on its
    /// end state until Memory lets it go (OD-42). See `StoryDecisionHold`.
    public private(set) var heldStoryDecision: StoryDecisionHold?

    /// Comfort and heat, as the system reports them: thermal state and video
    /// comfort mitigations. OD-50: a comfort pause or reduced immersion
    /// pauses the whole story with a short calm message, and the system's
    /// resume resumes it; very high heat shows a warning only. See
    /// `ComfortSignals` and `handleComfortResponse(_:)`.
    public let comfortSignals = ComfortSignals()

    /// The comfort message on show (OD-50). See `ComfortNoticePresenter`.
    public let comfortNotice = ComfortNoticePresenter()

    /// True while the story is paused because the system paused or shrank
    /// video for comfort (OD-50), and only then: a pause the person made is
    /// never resumed by the system's signal.
    public private(set) var isStoryPausedForComfort = false

    /// THE VIEWER-FACING CHOICE (OD-8): the question and its options, drawn
    /// while the story waits at a Cue that carries a Choice. See
    /// `ChoicePresenter` and `pickChoiceOption(_:)`.
    public let choices = ChoicePresenter()

    /// THE ONE AUTHORITY FOR MOVEMENT BETWEEN SEQUENCES.
    ///
    /// Completion, Interaction responses and host commands all emit a
    /// `NavigationRequest`; this decides, and `perform(_:)` carries it out.
    /// Nothing else may start a Sequence — two things that both can is how a
    /// chapter ends up playing two at once.
    @ObservationIgnored public var navigator = ExperienceNavigator()

    /// WHAT THE CHAPTER REMEMBERS, for this playback session.
    ///
    /// Owned here because a Chapter playback session is a property of the whole
    /// run, not of a Sequence — the engine, the gate wait and the navigator all
    /// read this one store. Never serialized; see `StoryStateStore`.
    public let storyState = StoryStateStore()
    /// Follows the active sequence's timed backdrop track. Lazy because it
    /// needs `self` as its presenter, and observation-ignored because it is a
    /// driver, not rendered state — tracking it would invalidate every view
    /// on each cue swap.
    @ObservationIgnored
    public private(set) lazy var backdropCues = BackdropCueDriver(presenter: self)
    /// The caption follower (FL-08), on the same authored clock — a
    /// driver, not rendered state, exactly like the backdrop's.
    @ObservationIgnored
    public private(set) lazy var captionCues = CaptionCueDriver(presenter: self)
    /// KEYED MATERIALS (FL-14). Same shape as the caption driver: polls the
    /// authored clock and presents ordinary overrides, which the existing
    /// realization already knows how to wear. Observation-ignored for the
    /// same reason — a driver is not rendered state, and tracking it would
    /// invalidate every view on each repaint.
    @ObservationIgnored
    public private(set) lazy var materialKeys = MaterialKeyDriver(presenter: self)
    /// KEYED STORED USD PARTS (FL-16), sampled on authored Sequence time.
    @ObservationIgnored
    public private(set) lazy var subElementKeys = SubElementKeyDriver(presenter: self)
    /// The mounted caption blocks; replaced whole when the showing set changes.
    @ObservationIgnored
    var captionRootEntity: Entity?

    // MARK: - Sequence routing

    public var activeSequenceId: String?
    /// The visit currently executing, so an entry can tell a fresh one from a
    /// resumed one. Runtime state: never serialized, cleared when the run ends.
    private var activeVisitID: SequenceVisitID?
    /// One suspended visit's interaction state per visit id. Bounded for the
    /// same reason the navigator bounds its history: an hour of navigating must
    /// not accumulate without limit.
    private var visitLedgers: [SequenceVisitID: InteractionLedger] = [:]
    /// ONE NAVIGATION AT A TIME (OD-46). How many navigations are being
    /// carried out right now: `navigate` and `performCompletion` count
    /// themselves, and an engine request reserves its place before its Task
    /// starts. While this is above zero, a navigation the ENGINE asks for (an
    /// authored Go To, a Sequence completing) is dropped, not queued: a second
    /// jump while one is happening is thrown away. A counter rather than a
    /// flag because `navigate` runs inside an engine request's reservation.
    private var navigationsInFlight = 0 {
        didSet {
            // A held story decision whose re-check was dropped because the
            // slot was taken is asked again once the slot frees, so a Memory
            // change made during a navigation that went nowhere still counts.
            guard navigationsInFlight == 0, recheckPendingForHeldDecision else { return }
            recheckPendingForHeldDecision = false
            recheckHeldStoryDecision()
        }
    }
    private var recheckPendingForHeldDecision = false
    /// The Cue the story is waiting at, and the last one answered and when.
    /// A spatial act that released a Cue is not ALSO an Explore Area's exit
    /// (OD-23: one act, one Cue), whichever of the two watches fired first.
    private var waitingCueGate: SegmentGateDTO?
    private var lastCueAnswered: (gate: SegmentGateDTO, at: Date)?

    /// THE CHOICE CUE THE STORY IS WAITING AT (OD-8), from its activation
    /// until it resolves. `picked` tells a timeout from a pick, so a timeout
    /// option is taken only when nobody picked.
    private struct ChoiceWait {
        let gate: SegmentGateDTO
        let visit: SequenceVisitID?
        let sequenceId: String?
        let segmentIndex: Int
        /// The engine's pause-aware clock when the wait began.
        let began: TimeInterval
        var picked = false
    }
    @ObservationIgnored private var choiceWait: ChoiceWait?

    /// THE ENGINE NAVIGATION IN FLIGHT (OD-111), if any: the one that holds
    /// the slot. A host Play cancels it (`cancelEngineNavigationForHost`),
    /// which puts the navigator back as it was before the engine's request,
    /// frees the slot and makes the engine's performer stop at its next
    /// check. `committed` is set once the engine has started the new
    /// Sequence: from there it is done, and nothing is left to cancel.
    private struct EngineNavigation {
        let token: Int
        let what: String
        let navigatorBefore: ExperienceNavigator
        var holdsSlot = true
        var canceled = false
        var committed = false
    }
    @ObservationIgnored private var engineNavigation: EngineNavigation?
    @ObservationIgnored private var engineNavigationCounter = 0
    /// How many engine navigations a host Play has canceled (OD-111). A
    /// diagnostic for hosts and tests.
    public private(set) var canceledEngineNavigationCount = 0

    private func pruneVisitLedgers() {
        guard visitLedgers.count > 64 else { return }
        visitLedgers.removeAll()
    }
    public var sequenceReentryNonce: Int = 0

    /// The currently-loaded ChapterScript experience document (if any).
    /// Populated by the live-load path (Maestro over Bonjour) or the
    /// consumer's "open project" file-importer flow. Drives sequence
    /// lookup for auto-advance and any timeline UI.
    public var loadedExperience: LoadedExperience? {
        didSet {
            // A newly loaded Chapter brings its own lighting. Editors that
            // keep a live document on top of this one (MaestroVision) follow
            // up through the same `applyEnvironment`.
            applyEnvironment(loadedExperience?.document.environment)
        }
    }

    /// Active hot-reload subscription, when connected to a live
    /// MaestroStudio over Bonjour. Cleared on disconnect.
    public var liveSubscription: LiveSubscription?
    public var liveSubscriptionDescriptor: LiveServerDescriptor?

    /// Set true *before* opening the immersive space when the user
    /// initiated playback via a Live menu. UI affordances watch this so
    /// a fast local-bundle load doesn't clobber the in-flight live fetch.
    public var isLoadingLiveExperience: Bool = false

    /// Descriptor of the live server we're currently *trying* to
    /// connect to. Populated when a live load kicks off and cleared on
    /// success or failure. Drives the loading overlay's
    /// "Connecting to <name>" label.
    public var liveLoadingDescriptor: LiveServerDescriptor?

    /// Last live-load failure surfaced to the user. Cleared on the next
    /// successful load or when the user dismisses the loading overlay.
    public var liveLoadError: String?

    /// Per-asset prefetch progress while the live experience is pulling
    /// files from the Mac. UI binds to this so authors see
    /// "streaming N/M" feedback during initial connect + hot-reloads.
    public let livePrefetchProgress = LivePrefetchProgress()

    /// Turns `loadedExperience.document.entities` into real RealityKit
    /// entities and registers them with `entityExecutor` +
    /// `videoEntityRegistry`. Initialized in `init`.
    public private(set) var documentEntities: DocumentEntityLoader!

    /// Live RealityKit anchor under the immersive root that
    /// `DocumentEntityLoader` parents materialized entities under. Set
    /// by the consumer's `ImmersiveView` after the `RealityView` make
    /// closure runs.
    public var immersiveSceneRoot: Entity? {
        didSet {
            // A REALITYKIT AUDIO SOURCE THAT IS NOT IN A SCENE IS SILENT.
            //
            // `SpatialAudioManager.audioRoot` is where every positional cue's
            // source entity is parented, and nothing had ever added it to a
            // scene — so `playAudio` ran, logged success, and produced no
            // sound. Head-locked cues were unaffected (they go through
            // AVAudioEngine, which needs no scene), which is exactly why this
            // read as "spatial audio is broken" rather than "audio is broken".
            //
            // Mounting it here, with the root, ties its lifetime to the one
            // thing it depends on.
            if let root = immersiveSceneRoot {
                if audioManager.audioRoot.parent !== root {
                    root.addChild(audioManager.audioRoot)
                }
                // AND the sound must find its emitter. `entityLookup` was
                // declared and read but never assigned, so every cue authored
                // `attachToEntity` silently fell back to the unplaced branch —
                // a positional sound at the origin, which is the one place an
                // author never put it. Resolved through the loader on each
                // call because `materialize` rebuilds its anchor.
                audioManager.entityLookup = { [weak self] name in
                    self?.documentEntities.entity(named: name)
                }
            } else {
                audioManager.audioRoot.removeFromParent()
                audioManager.entityLookup = nil
            }

            // The environment outlives a remount: a fresh root gets the spec
            // that was last asked for, which may be newer than the loaded
            // document's (a live edit lands through `applyEnvironment`).
            applyEnvironment(requestedEnvironment)

            // The host's LIVE document and resolver, where it has them. An
            // editor host used to let this build the scene from the load-time
            // pair and then build it all again from its own a moment later:
            // every model in the Chapter loaded twice on every mount.
            if let document = currentDocumentForStyling(), immersiveSceneRoot != nil {
                documentEntities.materialize(
                    document: document,
                    sceneRoot: immersiveSceneRoot,
                    mediaResolver: currentMediaResolver()
                )
                // A SCENE THAT ARRIVES MID-SEQUENCE IS BROUGHT TO THE MOMENT.
                // Whoever opens the space (this core, or a host's own
                // coordinator), the root can mount after Play: the Sequence's
                // opening actions have then already fired at an empty
                // registry, and fresh entities come up hidden. Everything
                // they should have revealed stayed hidden for the rest of the
                // Sequence (a Screen with its video playing, unseen). A seek
                // to where the clock already is pre-fires what came before.
                if sequenceEngine.isPlaying {
                    let now = sequenceEngine.sequenceAnimationTime
                    logger.info("[scene] built mid-Sequence at \(String(format: "%.2f", now))s: re-firing what came before")
                    sequenceEngine.seek(toSequenceTime: now)
                }
            }
            // Rebase the scene root to the viewer's head so all authored
            // coordinates are implicitly head-relative — entities placed
            // at (x, y, z) in Maestro appear at the same offset from the
            // viewer's head on device. Sampled once when the root mounts;
            // subsequent sequence changes don't re-rebase (which would
            // disorientingly shift the world).
            if immersiveSceneRoot != nil {
                Task { await rebaseSceneRootToHead() }
            }
        }
    }

    // MARK: - Chapter environment

    /// Owns whatever the Chapter's `EnvironmentSpec` adds to the scene root.
    private let environmentApplier = EnvironmentApplier()

    /// The spec most recently asked for, kept so a remounted scene root can be
    /// lit again without the caller having to remember to.
    @ObservationIgnored public private(set) var requestedEnvironment: EnvironmentSpec?

    /// THE ONE ROUTE from a Chapter's environment to the scene. Loading a
    /// Chapter, mounting the scene root and a live `setEnvironment` edit all
    /// come through here. Idempotent; `nil` removes everything it added.
    /// Before the root is mounted it only records the request.
    public func applyEnvironment(_ spec: EnvironmentSpec?) {
        requestedEnvironment = spec
        refreshSceneLight()
    }

    /// What stands around the viewer right now, for light. A still
    /// Environment is known here (`presentBackdrop`); an immersive video,
    /// cue or Clip, is reported by the video manager, and wins while it plays
    /// because it is what the viewer is actually inside.
    private var stillSurround: EnvironmentApplier.Surround = .room
    private var videoSurround: EnvironmentApplier.Surround?
    /// True while the presented Sequence is fully immersive. In passthrough
    /// the room IS the world, and its light is the right light.
    private var lightIsTheWorlds = false

    public var currentLightSurround: EnvironmentApplier.Surround {
        lightIsTheWorlds ? (videoSurround ?? stillSurround) : .room
    }

    private func refreshSceneLight() {
        guard let root = immersiveSceneRoot else { return }
        environmentApplier.apply(requestedEnvironment, surround: currentLightSurround, to: root)
    }

    // MARK: - Head-anchored scene root

    /// One-shot ARKit session that powers head sampling. Lazily started
    /// the first time the immersive scene root mounts; lives for the
    /// app's lifetime so `EntityActionExecutor.headTransformProvider`
    /// stays connected for the (still supported) legacy
    /// `headRelativePosition` action mode.
    private var arkitSession: ARKitSession?
    private var worldTracking: WorldTrackingProvider?
    /// Last eye height a plausibility-checked sample produced. The rebase
    /// falls back to it when a fresh mount's poll window expires without
    /// a believable pose.
    private var lastKnownEyeHeight: Float?

    /// Start head tracking, wire the executor's head provider, then sample
    /// once and set the scene root's transform to match — making world
    /// (0,0,0) = the viewer's head.
    ///
    /// A FRESH session runs on every mount: ARKit suspends providers when
    /// the immersive space closes and re-establishes the world origin when
    /// a new one opens — a provider kept from the previous space can
    /// return confidently-TRACKED poses in the stale coordinate frame
    /// (head at y≈0.1 "eye height", content on the floor). Session-per-
    /// mount keeps every sample in the current space's frame.
    private func rebaseSceneRootToHead() async {
        guard let root = immersiveSceneRoot else { return }
        let session = ARKitSession()
        let provider = WorldTrackingProvider()
        do {
            try await session.run([provider])
            self.arkitSession?.stop()
            self.arkitSession = session
            self.worldTracking = provider
            // Forward to the executor for the legacy head-relative
            // action mode (older documents that still use it).
            self.entityExecutor.headTransformProvider = { [weak provider] in
                provider?.sampleDeviceTransform(leveled: true)
            }
            // Spatial gates need the FULL head orientation — facing
            // uses pitch, which the leveled sample above strips.
            self.spatialTriggers.headTransformProvider = { [weak provider] in
                provider?.sampleDeviceTransform(leveled: false)
            }
        } catch {
            logger.warning("ARKit world tracking failed to start: \(error.localizedDescription)")
            return
        }
        // `session.run` returning doesn't guarantee an anchor is ready —
        // queryDeviceAnchor frequently returns nil (or, mid-relocalization,
        // an implausible pose) for the first frames. Poll, and only accept
        // a height a human head can actually be at: 0.5–2.5 m. y≈0.1 is
        // never an eye — it's an origin that hasn't settled.
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if let head = provider.sampleDeviceTransform(leveled: true),
               (0.5...2.5).contains(head.translation.y) {
                // Take ONLY the head's height (Y) — the viewer's eye
                // level. X / Z / yaw are intentionally NOT taken from
                // the head: an entity authored at (0, 0, -2) should
                // sit 2m in front of the tracking origin regardless
                // of where in the room the viewer is standing or which
                // way they're facing. Otherwise content would slide
                // with the user.
                lastKnownEyeHeight = head.translation.y
                root.transform = Transform(
                    scale: .one,
                    rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                    translation: SIMD3<Float>(0, head.translation.y, 0)
                )
                logger.info("Rebased scene root to eye height: y=\(head.translation.y) (X/Z/yaw left at tracking origin)")
                return
            }
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
        }
        if let fallback = lastKnownEyeHeight {
            root.transform = Transform(
                scale: .one,
                rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                translation: SIMD3<Float>(0, fallback, 0)
            )
            logger.warning("No plausible head pose within 4s; reusing last known eye height y=\(fallback).")
        } else {
            logger.warning("Head anchor never became available within 4s; scene root left at origin. Check NSWorldSensingUsageDescription in the app's Info.plist.")
        }
    }

    /// The wearer's current device transform from the live
    /// world-tracking session (nil before the immersive space has one,
    /// or mid-relocalization). `leveled` strips pitch/roll, leaving
    /// yaw + position — the sample an editor uses to align its
    /// presentation root to the wearer. Read-only: nothing here moves.
    public func sampleHeadTransform(leveled: Bool) -> Transform? {
        worldTracking?.sampleDeviceTransform(leveled: leveled)
    }

    // MARK: - Window / Space IDs

    /// Identifier the consumer's `ImmersiveSpace` scene was declared
    /// with. Passed to the injected `openSpace` closure when a sequence's
    /// presentation requires immersion.
    public let immersiveSpaceID: String

    // MARK: - Immersive space lifecycle

    public enum ImmersiveSpaceState: Sendable {
        case closed
        case inTransition
        case open
    }

    public var immersiveSpaceState: ImmersiveSpaceState = .closed
    public var immersionStyle: ImmersionStyle = .full {
        didSet { immersionRevision &+= 1 }
    }
    /// Equatable pulse for `immersionStyle` (which isn't Equatable).
    /// Scene bodies do NOT track @Observable reads, so a computed Binding
    /// inside `.immersionStyle(selection:)` never re-evaluates when the
    /// model changes the style mid-session (sequence presentation
    /// switches while the space is open silently no-op). Apps must keep
    /// the selection in scene @State and sync it from a VIEW via
    /// `.onChange(of: core.immersionRevision)`.
    public private(set) var immersionRevision: Int = 0

    /// Kaiser pattern: openSpace / dismissSpace injected from the
    /// consumer app's `.task` where `@Environment(\.openImmersiveSpace)`
    /// / `\.dismissImmersiveSpace` are available. Keeps the core
    /// non-View code.
    public var openSpace: ((String) async -> OpenImmersiveSpaceAction.Result)?
    public var dismissSpace: (() async -> Void)?

    /// Currently-bound USDZ backdrop entity, parented under
    /// `immersiveSceneRoot`. Tracked so `applySequenceBackdrop` can swap
    /// or tear it down when the next sequence activates. Nil for video /
    /// image / no-backdrop sequences.
    public var currentBackdropUSDZ: Entity?

    /// Which backdrop USDZ load is the current one. Bumped on every apply and
    /// on every teardown; a completion whose generation has moved on discards
    /// itself instead of installing a second copy.
    private var backdropUSDZGeneration: UInt64 = 0
    /// The asset the mounted (or in-flight) USDZ backdrop came from, so the
    /// same world presented again is MOVED rather than reloaded.
    private var backdropUSDZAssetId: String?

    /// Whether the skybox entity currently holds a `.image` backdrop's
    /// sphere mesh + UnlitMaterial. Tracked separately from the
    /// VideoPlayerComponent path so sequence transitions know which
    /// teardown to run.
    public var currentImageSkyboxActive: Bool = false

    /// The PLACEMENT of whatever backdrop is mounted — the cue's
    /// `transform`, resolved. Applied to the skybox shell and to a USDZ
    /// backdrop alike by `applyBackdropPlacement`, and re-applied after every
    /// mount because the mounts themselves rewrite the shell's scale.
    private var currentBackdropTransform: BackdropTransform = .identity

    /// The skybox shell's own transform before any cue placed it, captured
    /// on first placement. The host may have positioned the shell in its
    /// scene; a cue's placement composes ON TOP of that and a reset returns
    /// to it, rather than to an origin the host never authored.
    private var skyboxRestTransform: Transform?

    /// Channel name reserved for the sequence-level immersive backdrop
    /// video. Independent from any per-segment `playVideo` channel so
    /// authors can mix the two without clobbering each other (last
    /// write to the "skybox" entity still wins on visionOS — sequence
    /// backdrop runs at sequence start; segment-level skybox plays can
    /// override it intentionally).
    public static let backdropVideoChannel = "sequenceBackdrop"

    /// Name of the ambient backdrop entity in the consumer's
    /// RealityKit scene that should be hidden while a Maestro
    /// experience is loaded. The consumer's `ImmersiveView` typically
    /// names a Reality Composer Pro anchor with this string. Pass
    /// `nil` to disable the hide/restore behavior entirely.
    public let ambientBackdropName: String?

    // MARK: - Init

    public init(
        immersiveSpaceID: String = "ChapterPlayerImmersiveSpace",
        ambientBackdropName: String? = nil
    ) {
        self.immersiveSpaceID = immersiveSpaceID
        self.ambientBackdropName = ambientBackdropName
        self.audioExecutor = AudioActionExecutor(audioManager: audioManager)
        self.videoExecutor = VideoActionExecutor(videoManager: videoManager)
        // After the executors: `self` is only usable once every stored `let`
        // has a value, and both of these read `spatialTriggers` off self.
        self.gateDetection = GateDetectionController(detector: spatialTriggers)
        self.interactions = InteractionController(detector: spatialTriggers)
        // The sequence backdrop's video channel is owned at the
        // ChapterPlayerCore scope (one backdrop per sequence, swapped at
        // sequence transitions), not at the sequence-engine scope.
        // Protect it from `videoManager.stopAll()` which the engine
        // calls on every sequence transition to wipe per-segment video
        // state — see `VideoPlaybackManager.protectedChannels`.
        videoManager.protectedChannels.insert(Self.backdropVideoChannel)

        // Wire executors into the engine
        sequenceEngine.entityExecutor = entityExecutor
        sequenceEngine.audioExecutor = audioExecutor
        sequenceEngine.videoExecutor = videoExecutor
        sequenceEngine.attachmentExecutor = attachmentExecutor
        sequenceEngine.effectExecutor = effectExecutor

        // Spatial gate detection: resolve gate targets out of the entity
        // registry; the head provider is wired when world tracking starts
        // (`rebaseSceneRootToHead`).
        sequenceEngine.gateDetector = gateDetection
        sequenceEngine.backdropDriver = backdropCues
        sequenceEngine.followingSequenceProvider = { [weak self] in
            guard let self, let current = self.sequenceEngine.currentSequence else { return nil }
            // A DRY RUN OF THE ONE NAVIGATOR, on a copy (it is a value): the
            // same decision completion will get, with nothing recorded.
            var probe = self.navigator
            let outcome = probe.handleCompletion(
                current.onComplete.authored, from: current.id,
                exists: { self.sequenceFromLoadedDocument(id: $0) != nil },
                start: { self.loadedExperience?.document.defaultSequenceId },
                // The same Memory the completion itself will read, so a
                // "Continue by the Story…" ending warms the branch it will
                // actually take rather than its Otherwise.
                storyState: self.storyState.ledger)
            guard case .enter(let next, _, _) = outcome else { return nil }
            return self.sequenceFromLoadedDocument(id: next)
        }
        sequenceEngine.captionDriver = captionCues
        // KEYED MATERIALS (FL-14) on the same authored clock, wired the same
        // way: the driver polls, the engine hands it the Sequence's tracks
        // and the Chapter's stored overrides to rest on.
        sequenceEngine.materialKeyDriver = materialKeys
        sequenceEngine.subElementKeyDriver = subElementKeys
        sequenceEngine.subElementActionExecutor = self
        sequenceEngine.materialKeyTracksProvider = { [weak self] in
            self?.sequenceEngine.currentSequence?.materialKeyTracks
        }
        sequenceEngine.subElementKeyTracksProvider = { [weak self] in
            self?.sequenceEngine.currentSequence?.subElementKeyTracks
        }
        sequenceEngine.entityDefinitionsProvider = { [weak self] in
            self?.loadedExperience?.document.entities ?? []
        }
        // The per-frame video surface (FL-09 … FL-13) reads the AUTHORED
        // clock — the caption driver's clock — and the Sequence's Effect
        // Key curves; never wall time.
        videoManager.sequenceClock = { [weak self] in
            self?.sequenceEngine.sequenceAnimationTime ?? 0
        }
        videoManager.effectKeyTracksProvider = { [weak self] in
            self?.sequenceEngine.currentSequence?.effectKeyTracks ?? []
        }
        sequenceEngine.captionStylesProvider = { [weak self] in
            self?.loadedExperience?.document.captionStyles
        }
        spatialTriggers.entityProvider = { [weak self] name in
            self?.entityExecutor.entityRegistry[name]
        }
        cuePrompts.sceneRootProvider = { [weak self] in
            self?.immersiveSceneRoot
        }
        cuePrompts.entityProvider = { [weak self] name in
            self?.entityExecutor.entityRegistry[name]
        }

        // Interactions: same registry, and responses handed straight back to
        // the engine so they run through the executors a segment's actions use.
        sequenceEngine.interactionController = interactions
        interactions.entityProvider = { [weak self] name in
            self?.entityExecutor.entityRegistry[name]
        }
        interactions.subElementProvider = { [weak self] target in
            self?.documentEntities?.subElement(target)
        }
        interactions.perform = { [weak self] actions in
            self?.sequenceEngine.performActions(actions)
        }
        // The LIVE document where a host has one. An editor's Interactions
        // are authored after load; arming from the load-time snapshot armed
        // the Chapter as opened, so an Interaction made this session never
        // answered a tap until the Chapter was reopened.
        environmentApplier.mediaURL = { [weak self] file, isVideo in
            self?.resolveBackdropAssetURL(file: file, kind: isVideo ? .video : .image)
        }
        videoManager.onImmersiveSurroundChanged = { [weak self] surround in
            guard let self else { return }
            self.videoSurround = surround.map {
                .video(file: $0.file, time: $0.sourceIn, layout: $0.layout, coverage: $0.coverage)
            }
            // An immersive Clip can play in a Sequence that presented no
            // Environment at all, so the presentation is read here too.
            if surround != nil, let sequence = self.sequenceEngine.currentSequence {
                self.lightIsTheWorlds = sequence.presentation == .immersive
            }
            self.refreshSceneLight()
        }
        interactions.documentProvider = { [weak self] in
            self?.currentDocumentForStyling()
        }
        // OD-21: arm only the PLAYING Sequence's Interactions. The engine sets
        // `currentSequence` before it re-installs them, so this reads the new
        // Sequence; with no Sequence playing the controller arms the union.
        interactions.playingSequenceProvider = { [weak self] in
            self?.sequenceEngine.currentSequence?.id
        }
        // OD-87: the AUTHORED Sequence, so a Cue wait reads each clip's
        // "While waiting at a Cue" setting (Keep Playing, Hold, Stop).
        sequenceEngine.sequenceDTOProvider = { [weak self] id in
            self?.currentDocumentForStyling()?.sequences.first { $0.id == id }
        }
        // OD-24: Flat View (and the Convergence value) read from the playing
        // Sequence's authored keys and the document's video decisions.
        videoManager.authoredStereoProvider = { [weak self] in
            guard let self,
                  let document = self.currentDocumentForStyling(),
                  let id = self.sequenceEngine.currentSequence?.id,
                  let sequence = document.sequences.first(where: { $0.id == id })
            else { return nil }
            return HeadsetStereoPresentation.Authored(
                sequence: sequence, videoInterpretations: document.editorMetadata?.videoInterpretations ?? [:])
        }

        // THE GATE, AS THE SECOND CONSUMER OF ONE SEMANTIC ACTIVATION.
        interactions.offerToGate = { [weak self] entityName, trigger, interactionRan, isAccessible in
            self?.offerActivationToGate(entityName: entityName, trigger: trigger,
                                        interactionRan: interactionRan,
                                        isAccessible: isAccessible) ?? false
        }

        // An ACTIVE gate publishes an accessible equivalent on its target, and
        // withdraws it when it resolves. Event-driven, never polled.
        gateDetection.onGateActivated = { [weak self] gate in
            guard let self else { return }
            let authored = self.authoredGate(for: gate)
            self.waitingCueGate = authored
            // A CUE THAT CARRIES A CHOICE (OD-8) shows its question and its
            // options instead of a Prompt and a waiting sign, and offers no
            // "Continue": it is answered by a pick (or its timeout).
            if GateActivation.waitsForChoice(authored) {
                self.beginChoiceWait(authored)
                return
            }
            // THE VIEWER SEES WHAT THE STORY IS WAITING FOR (OD-38): the
            // Cue's Prompt and a small waiting sign, near its Object.
            self.cuePrompts.show(CuePromptPlan.plan(for: gate))
            guard let target = gate.targetEntity else { return }
            // A STORY-CONDITION GATE PUBLISHES NOTHING, and that is the
            // accessible behavior rather than a gap in it. It is not waiting
            // for a person to do anything — it is waiting for a fact — so there
            // is no physical act to offer an equivalent FOR, and offering
            // "Continue" would let assistive technology bypass a condition the
            // author set. Every gate that asks for an act still gets one.
            guard let trigger = GateActivation.trigger(for: gate.type.authored) else { return }
            self.interactions.setGateAction(
                entityName: target,
                label: GateActivation.accessibleLabel(prompt: gate.prompt),
                trigger: trigger)
        }
        gateDetection.onGateResolved = { [weak self] in
            guard let self else { return }
            if let gate = self.waitingCueGate { self.lastCueAnswered = (gate, Date()) }
            self.waitingCueGate = nil
            self.interactions.clearGateActions()
            self.cuePrompts.hide()
            // Answered, timed out, stopped or seeked past: the options go.
            self.endChoiceWait()
        }
        choices.sceneRootProvider = { [weak self] in
            self?.immersiveSceneRoot
        }
        choices.entityProvider = { [weak self] name in
            self?.entityExecutor.entityRegistry[name]
        }
        choices.onPick = { [weak self] optionId in
            _ = self?.pickChoiceOption(optionId)
        }
        comfortNotice.sceneRootProvider = { [weak self] in
            self?.immersiveSceneRoot
        }

        // STORY STATE. The engine applies mutations into this session's store;
        // the store tells a waiting story-condition boundary that a fact it
        // waits for became true. Event-driven both ways, so nothing polls the
        // Chapter to notice a counter went up.
        sequenceEngine.storyState = storyState
        storyState.onChange = { [weak self] in
            self?.sequenceEngine.storyStateDidChange()
            // A STORY DECISION THAT FOUND NO MATCH re-checks on every Memory
            // change, and moves on once a case matches (OD-42).
            self?.recheckHeldStoryDecision()
        }

        // EXPLORE. The clocks come from the engine, so there is no second timer
        // and nothing that keeps running while playback is paused.
        sequenceEngine.storyRegions = storyRegions
        storyRegions.runtimeClock = { [weak self] in
            // The engine's PAUSE-AWARE playback clock. It keeps advancing past
            // the authored total while the story is held, which is exactly what
            // makes it the runtime clock — and it subtracts paused time, so a
            // suspended experience does not age its region.
            self?.sequenceEngine.totalElapsed ?? 0
        }
        storyRegions.authoredClock = { [weak self] in
            // The Sequence clock. The engine clamps it at a segment's end during a
            // gate wait, and that clamping IS the Explore hold.
            self?.sequenceEngine.sequenceAnimationTime ?? 0
        }
        storyRegions.releaseStory = { [weak self] in
            // The SAME call a tap makes. One way out of a hold.
            self?.sequenceEngine.satisfyGate()
        }
        storyRegions.setAnimationLoopOverride = { [weak self] entity, sampleTime in
            self?.entityExecutor.animationLoopOverrides[entity] = sampleTime
        }
        storyRegions.applyContinuation = { [weak self] target, behavior, phase in
            self?.applyStoryContinuation(target: target, behavior: behavior, phase: phase)
        }
        storyRegions.applyExitFade = { [weak self] target, seconds in
            self?.applyStoryExitFade(target: target, seconds: seconds)
        }
        // OD-50: wired BEFORE observation starts, so a device that is
        // already very warm shows its warning from the first reading.
        comfortSignals.onResponse = { [weak self] response in
            self?.handleComfortResponse(response)
        }
        // A comfort pause the PERSON ended (Play, a Cue's act, a Stop) takes
        // its message with it. The engine reports every transport change
        // here; this is the only reader, and the check is one comparison.
        sequenceEngine.onStatusUpdate = { [weak self] _ in
            self?.comfortPauseEndedElsewhereIfResumed()
        }
        comfortSignals.startObservingThermalState()
        videoManager.onVideoComponentAttached = { [weak self] entity in
            self?.comfortSignals.observeVideoComfort(in: entity.scene)
        }
        storyRegions.holdDidBegin = { [weak self] region in
            self?.applyDefaultStoryHold(for: region)
        }
        storyRegions.holdDidEnd = { [weak self] in
            self?.releaseStoryHolds()
        }
        // EXIT DETECTION FROM AREA ENTRY (OD-23). While the first pass plays,
        // the exit's act is sensed by the same detector a waiting Cue uses,
        // and its accessible equivalent is offered, so an early act counts.
        storyRegions.exitWatchDidBegin = { [weak self] region in
            self?.armAreaExit(region.exit)
        }
        // THE RESPONSE (OD-96): run through the one action path an
        // Interaction's response takes, so a Go To, a sound or a Memory
        // change means one thing in this app.
        storyRegions.runResponse = { [weak self] region in
            self?.runAreaResponse(region)
        }
        // A LOOPING AREA'S MEDIA (OD-25, OD-99): everything inside its range
        // repeats with it while it waits, sound included.
        storyRegions.areaLoopDidAdvance = { [weak self] region, previous, dwell in
            self?.advanceAreaLoop(region, from: previous, to: dwell)
        }
        storyRegions.areaLoopWillRelease = { [weak self] region, dwell in
            self?.releaseAreaLoop(region, dwell: dwell)
        }
        storyRegions.exitWatchDidEnd = { [weak self] in
            self?.gateDetection.disarmAreaExit()
            self?.interactions.clearAreaExitAction()
        }

        // DocumentEntityLoader needs the two executors it registers
        // entities with. Constructed after self is fully initialized so
        // both executors are wired up.
        self.documentEntities = DocumentEntityLoader(
            entityExecutor: entityExecutor,
            videoManager: videoManager,
            ambientBackdropName: ambientBackdropName
        )

        // Sequence lifecycle callbacks
        sequenceEngine.onSequenceStarted = { [weak self] sequenceId in
            self?.activeSequenceId = sequenceId
            self?.sequenceReentryNonce += 1
        }

        // Auto-advance: follow CompletionAction.autoAdvance(nextSequenceId:)
        // to the next sequence. The next sequence must come from the
        // currently-loaded ChapterScript document — the core no longer
        // ships bundled demo sequences as a fallback.
        // AN AUTHORED NAVIGATION — from an Interaction response, or from any
        // segment — reaches the ONE navigator here.
        //
        // Accessibility gets this for free: an accessible activation runs the
        // same `InteractionSpec.actions` a physical one does, so it produces
        // the same `.navigate` action, the same intent and the same transition.
        // There is no accessibility-specific Sequence change (Phase 6's rule).
        sequenceEngine.onNavigationRequested = { [weak self] intent in
            guard let self else { return }
            self.startEngineNavigation("a Go To") {
                // EXPLICIT NAVIGATION LEAVES AN EXPLORE REGION IMMEDIATELY.
                // Satisfying a Region's exit is a different act and does not
                // come through here — see `docs/EXPERIENCE_FLOW.md` §6.
                self.storyRegions.teardown()
                await self.navigate(intent, source: .host)
            }
        }

        // COMPLETION EMITS AN INTENT. IT DOES NOT NAVIGATE.
        //
        // This used to be a self-contained `while true` chain-walker that
        // resolved targets, applied presentation and called `playAndAwait`
        // inline — a second navigator, which Phase 8's Go To would have made a
        // third. `ExperienceNavigator` now decides, and this performs. Legacy
        // `autoAdvance` therefore behaves identically while sharing one
        // execution path with every new navigation kind.
        sequenceEngine.onSequenceComplete = { [weak self] completion in
            guard let self, let finished = self.activeSequenceId else { return }
            // A FINISHED SEQUENCE IS AT ITS END. Captured now (the engine
            // also holds its clock there once it stops, OD-45), so a
            // Return · Resume into it lands on its last Segment as the Mac
            // does, rather than replaying it from Segment 1.
            let endPosition = self.sequenceEngine.totalDuration
            let authored = completion.authored
            self.startEngineNavigation("a Sequence ending") {
                await self.performCompletion(authored, from: finished, endingAt: endPosition)
            }
        }
    }

    // MARK: - Engine navigation: one at a time, and a host Play wins (OD-46, OD-111)

    /// RESERVE THE SLOT AND CARRY OUT AN ENGINE-RAISED NAVIGATION, or drop it
    /// when another navigation holds the slot (OD-46). Returns false when
    /// dropped. `body` runs in its own Task with `EngineNavigationContext`
    /// set, so everything it calls knows it is the engine's request, which a
    /// host Play may cancel (OD-111).
    @discardableResult
    private func startEngineNavigation(_ what: String,
                                       _ body: @escaping @MainActor () async -> Void) -> Bool {
        guard reserveEngineNavigation(what) else { return false }
        engineNavigationCounter += 1
        let token = engineNavigationCounter
        engineNavigation = EngineNavigation(token: token, what: what, navigatorBefore: navigator)
        Task { @MainActor in
            defer { self.finishEngineNavigation(token) }
            // Canceled before it began: nothing was decided, nothing to undo.
            guard self.engineNavigationIsCurrent(token) else { return }
            await EngineNavigationContext.$token.withValue(token) {
                await body()
            }
        }
        return true
    }

    /// Is the engine navigation `token` still wanted? False once a host Play
    /// canceled it, or once another took its place.
    private func engineNavigationIsCurrent(_ token: Int) -> Bool {
        guard let navigation = engineNavigation, navigation.token == token else { return false }
        return !navigation.canceled
    }

    /// The engine navigation's Task finished: release its slot, unless a
    /// host Play already did when it canceled it.
    private func finishEngineNavigation(_ token: Int) {
        guard let navigation = engineNavigation, navigation.token == token else { return }
        engineNavigation = nil
        if navigation.holdsSlot { navigationsInFlight -= 1 }
    }

    /// May the code running now carry on? Always for a host's own call; for
    /// an engine navigation, only while no host Play has canceled it.
    private var mayProceed: Bool {
        guard let token = EngineNavigationContext.token else { return true }
        return engineNavigationIsCurrent(token)
    }

    /// Count a navigation that is running now, for the one-at-a-time rule.
    /// An engine navigation's slot already counts everything it calls, so
    /// only a host's call counts itself; that is what lets a host Play free
    /// the slot of the engine navigation it cancels at once.
    private func countNavigation() -> Bool {
        guard EngineNavigationContext.token == nil else { return false }
        navigationsInFlight += 1
        return true
    }

    /// A HOST PLAY CANCELS AN IN-FLIGHT ENGINE NAVIGATION AND WINS (OD-111,
    /// owner decision). Called at the start of every host entry (`playSequence`,
    /// `navigate`, `performCompletion` called by a host, and `stopSequence`,
    /// a Stop being the person's request too). The engine's request
    /// is undone where it stands: the navigator goes back to what it was
    /// before that request, its slot is freed (so the new Sequence's own t=0
    /// Go To is still accepted), and its performer stops at its next check
    /// without starting anything. A navigation that already started its
    /// Sequence is finished, not canceled.
    private func cancelEngineNavigationForHost() {
        guard EngineNavigationContext.token == nil,
              var navigation = engineNavigation,
              !navigation.canceled, !navigation.committed else { return }
        navigation.canceled = true
        navigator = navigation.navigatorBefore
        // The person's request moves the story on, so no held ending is still
        // deciding, and freeing the slot below must not start its re-check.
        heldStoryDecision = nil
        recheckPendingForHeldDecision = false
        if navigation.holdsSlot {
            navigation.holdsSlot = false
            navigationsInFlight -= 1
        }
        engineNavigation = navigation
        canceledEngineNavigationCount += 1
        logger.info("[flow] a host Play canceled \(navigation.what, privacy: .public) in progress")
    }

    /// The engine navigation running now has started its Sequence.
    private func commitEngineNavigation() {
        guard let token = EngineNavigationContext.token,
              engineNavigation?.token == token else { return }
        engineNavigation?.committed = true
    }

    /// RESERVE THE ONE NAVIGATION SLOT for a request the engine raised, or
    /// drop it (OD-46). Synchronous on purpose: the check and the reservation
    /// happen in the same main-actor turn the engine called back in, so two
    /// requests raised back to back cannot both pass before either Task runs.
    /// The caller's Task releases the slot when it finishes.
    ///
    /// The new Sequence's own t=0 actions are NOT dropped by this: the
    /// engine's segment loop is a Task it spawns from `play`, the last call
    /// `playSequence` makes, and the slot is released with no suspension in
    /// between, so that loop first runs after the slot is free.
    ///
    /// A host's own `navigate` (Play, a QA harness) is never dropped: it is
    /// the person's request. It counts while it runs, so the engine's
    /// requests during it are.
    @MainActor
    private func reserveEngineNavigation(_ what: String) -> Bool {
        guard navigationsInFlight == 0 else {
            logger.debug("[flow] dropped \(what, privacy: .public): another navigation is in progress")
            return false
        }
        navigationsInFlight += 1
        return true
    }

    /// THE ONE COMPLETION PATH. A Sequence finished and its authored ending
    /// says where the story goes: the navigator decides, `perform` carries
    /// it out.
    ///
    /// Public so a host's QA harness reaches the SAME decision the engine's
    /// completion does, with the same Memory and the same position, rather
    /// than a copy of the navigator call that supplies its own arguments.
    /// A "Continue by the Story…" ending is resolved against this session's
    /// Memory; resolved against an empty ledger, every branch took its
    /// Otherwise on the headset.
    ///
    /// - Parameter position: where the finished visit stands, which is its
    ///   end. A completion that suspends it (Continue to) records this as
    ///   the place a Return · Resume comes back to.
    @MainActor
    public func performCompletion(_ completion: CompletionActionDTO,
                                  from finished: String,
                                  endingAt position: TimeInterval) async {
        cancelEngineNavigationForHost()
        let counted = countNavigation()
        defer { if counted { navigationsInFlight -= 1 } }
        guard mayProceed else { return }
        heldStoryDecision = nil
        let outcome = navigator.handleCompletion(
            completion,
            from: finished,
            exists: { self.sequenceFromLoadedDocument(id: $0) != nil },
            start: { self.loadedExperience?.document.defaultSequenceId },
            currentPosition: position,
            storyState: storyState.ledger,
            // OD-98: what the story remembers now goes with the visit this
            // ending leaves, so a Resume of it can put that Memory back.
            memorySnapshot: storyState.memorySnapshot)
        // A DECISION THAT FOUND NO MATCH HOLDS, and remembers what it was
        // waiting to decide, so a later Memory change can decide again
        // (OD-42). Recorded before `perform`, which does nothing for `.stay`.
        heldStoryDecision = StoryDecisionHold.holding(
            after: completion, from: finished, endingAt: position, outcome: outcome)
        if heldStoryDecision != nil {
            logger.info("[flow] '\(finished, privacy: .public)' ended on a story decision with no match; holding until Memory changes")
        }
        await perform(outcome)
    }

    /// MEMORY CHANGED WHILE A STORY DECISION HOLDS (OD-42): ask it again,
    /// and move on through the one completion path as soon as a case
    /// matches. Nothing happens while it still matches nothing.
    ///
    /// Only while the Sequence that ended on it is still where it stopped:
    /// a Play, a jump or a seek since then has moved the story on, and the
    /// held decision is no longer the one in front of the viewer. A
    /// re-check that finds another navigation in progress waits for the
    /// next Memory change rather than racing it (OD-46).
    private func recheckHeldStoryDecision() {
        guard let held = heldStoryDecision else { return }
        guard activeSequenceId == held.sequenceId, !sequenceEngine.isPlaying else {
            heldStoryDecision = nil
            return
        }
        guard held.movesOn(in: storyState.ledger) else { return }
        let started = startEngineNavigation("a story decision re-check") {
            await self.performCompletion(held.completion, from: held.sequenceId,
                                         endingAt: held.endPosition)
        }
        guard started else {
            recheckPendingForHeldDecision = true
            return
        }
        heldStoryDecision = nil
        logger.info("[flow] Memory changed; the story decision at the end of '\(held.sequenceId, privacy: .public)' now matches")
    }

    /// START SENSING AN EXPLORE AREA'S EXIT AT AREA ENTRY (OD-23): the
    /// spatial act through the shared detector, and the accessible
    /// equivalent on its Object. A tap needs no watch; it arrives through
    /// `offerActivationToGate`.
    private func armAreaExit(_ exit: SegmentGateDTO) {
        gateDetection.armAreaExit(exit) { [weak self] in
            _ = self?.areaExitActSensed(exit)
        }
        if let target = exit.targetEntity, !target.isEmpty,
           let trigger = GateActivation.trigger(for: exit.type) {
            interactions.setAreaExitAction(entityName: target,
                                           label: GateActivation.accessibleLabel(for: exit),
                                           trigger: trigger)
        }
    }

    /// THE AREA'S EXIT WATCH SENSED ITS ACT during the first pass (OD-23):
    /// a facing dwell, an approach or a grab, from the shared detector.
    ///
    /// ONE ACT, ONE ANSWER (OD-121), as for a tap (`offerActivationToGate`).
    /// The same grab can fire this watch and a waiting Cue's own watch, in
    /// either order: a Cue waiting for it, or one it answered a moment ago,
    /// keeps it, and the Area's watch hears the next act. The exit's Memory
    /// conditions and the Area's exit timing apply exactly as for a tap.
    ///
    /// Public so the rule is tested on the runtime a headset runs, without a
    /// detector. Returns true when the act finished the Area.
    @discardableResult
    public func areaExitActSensed(_ exit: SegmentGateDTO) -> Bool {
        // The act AND what the story remembers, as at the boundary.
        guard GateActivation.storyConditionsHold(exit, in: storyState.ledger) else { return false }
        guard let trigger = GateActivation.trigger(for: exit.type) else {
            // An exit no act answers (a Memory or Orchestrator exit) has
            // nothing for a watch to sense.
            return false
        }
        let act = SemanticActivation(entityName: exit.targetEntity, trigger: trigger,
                                     interactionRan: false, isAccessible: false)
        if sequenceEngine.isWaiting, let gate = sequenceEngine.currentGate,
           GateActivation.satisfies(gate: authoredGate(for: gate), activation: act, state: storyState.ledger) {
            return false
        }
        return storyRegions.offerEarlyExit(act, state: storyState.ledger,
                                           answeredACue: actWasJustSpentOnACue(act))
    }

    /// Did this act release a Cue a moment ago? Then it is spent there: one
    /// act answers one thing (OD-121). Half a second covers the two routes
    /// (a Cue's own watch and the Area's) reporting the same act in turn.
    private func actWasJustSpentOnACue(_ act: SemanticActivation) -> Bool {
        guard let last = lastCueAnswered, Date().timeIntervalSince(last.at) < 0.5 else { return false }
        return GateActivation.satisfies(gate: last.gate, activation: act, state: storyState.ledger)
    }

    // MARK: - Explore Area: the Response and the loop (OD-96, OD-25, OD-99)

    /// RUN AN AREA'S RESPONSE through the one engine path an Interaction's
    /// response takes. Empty is Continue, which the controller performs by
    /// letting the story go; nothing runs here for it.
    private func runAreaResponse(_ region: StoryRegion) {
        let actions = region.responseActions.compactMap { dto -> SegmentAction? in
            do { return try SegmentAction(dto: dto) } catch {
                logger.warning("[explore] Area '\(region.id)' Response carries an action this build cannot run: \(String(describing: error))")
                return nil
            }
        }
        guard !actions.isEmpty else { return }
        logger.info("[explore] Area '\(region.id)' runs its Response: \(actions.count) action(s)")
        sequenceEngine.performActions(actions)
    }

    /// What a looping Area is replaying, worked out once as its hold begins.
    private struct AreaLoopMedia {
        let regionId: String
        /// The occurrences that loop with the Area: inside its range, and not
        /// opted out by their own continuation.
        let occurrences: [StoryRegionLoopOccurrence]
        /// The occurrence each video channel is showing, so a restart of the
        /// same clip seeks instead of building a new player.
        var videoOnChannel: [String: String]
    }
    @ObservationIgnored private var areaLoopMedia: AreaLoopMedia?

    /// A start this close to an occurrence's own beginning starts it from the
    /// top. Wider than a tick, so a clip that loops on its own (which cannot
    /// be started part-way) still rejoins the Area's loop at its place.
    private static let areaLoopStartTolerance: TimeInterval = 0.25

    private func advanceAreaLoop(_ region: StoryRegion, from previous: TimeInterval?,
                                 to dwell: TimeInterval) {
        if previous == nil || areaLoopMedia?.regionId != region.id {
            let occurrences = loopingOccurrences(in: region)
            var showing: [String: String] = [:]
            // What each Screen shows at the boundary: the occurrence that ran
            // up to the Area's end.
            for occurrence in occurrences
            where occurrence.medium == .video && occurrence.end >= region.endTime - 1e-4 {
                showing[occurrence.channel] = occurrence.actionId
            }
            areaLoopMedia = AreaLoopMedia(regionId: region.id, occurrences: occurrences,
                                          videoOnChannel: showing)
            if !occurrences.isEmpty {
                logger.info("[explore] Area '\(region.id)' loops \(occurrences.count) media occurrence(s) with its range")
            }
        }
        guard let loop = areaLoopMedia, !loop.occurrences.isEmpty else { return }
        performAreaLoop(StoryRegionLoopMedia.commands(for: loop.occurrences, region: region,
                                                      from: previous, to: dwell))
    }

    /// The Area's exit released it: what runs past the Area goes back to the
    /// authored boundary, and what ended with the Area stops.
    private func releaseAreaLoop(_ region: StoryRegion, dwell: TimeInterval) {
        guard let loop = areaLoopMedia, loop.regionId == region.id else { return }
        performAreaLoop(StoryRegionLoopMedia.exitCommands(for: loop.occurrences, region: region,
                                                          dwell: dwell))
        areaLoopMedia = nil
    }

    /// The occurrences of the playing Sequence that loop with `region`.
    /// Read from the document by stable action id, the same way a
    /// continuation names them; an occurrence's own continuation wins
    /// (`StoryHoldPlan.areaLoopCommand`). A Sequence-crossing (ambient) sound
    /// is never the Area's to loop.
    private func loopingOccurrences(in region: StoryRegion) -> [StoryRegionLoopOccurrence] {
        guard let sequenceId = sequenceEngine.currentSequence?.id,
              let sequence = loadedExperience?.document.sequences.first(where: { $0.id == sequenceId })
        else { return [] }
        return StoryRegionLoopMedia.occurrences(in: sequence.segments, region: region).filter { occurrence in
            if case .playAudio(let audio) = occurrence.opening, audio.scope == .ambient { return false }
            let authored = region.authoredContinuation(for: .occurrence(actionId: occurrence.actionId))
            let content: StoryHoldPlan.Content = occurrence.medium == .video ? .video : .audio
            return StoryHoldPlan.areaLoopCommand(for: authored?.behavior, exitFade: authored?.exitFade,
                                                 on: content) == .loopWithArea
        }
    }

    private func performAreaLoop(_ commands: [StoryRegionLoopMedia.Command]) {
        for command in commands {
            switch command {
            case .stop(let occurrence):
                switch occurrence.medium {
                case .audio:
                    audioExecutor.stop(channel: occurrence.channel)
                case .video:
                    // Only the clip this loop put there: another occurrence
                    // may already own the Screen.
                    guard areaLoopMedia?.videoOnChannel[occurrence.channel] == occurrence.actionId else { continue }
                    videoExecutor.stop(channel: occurrence.channel)
                    areaLoopMedia?.videoOnChannel[occurrence.channel] = nil
                }
            case .start(let occurrence, let elapsed):
                switch occurrence.medium {
                case .audio: startLoopedAudio(occurrence, elapsed: elapsed)
                case .video: startLoopedVideo(occurrence, elapsed: elapsed)
                }
            }
        }
    }

    private func startLoopedAudio(_ occurrence: StoryRegionLoopOccurrence, elapsed: TimeInterval) {
        guard case .playAudio(let dto) = occurrence.opening,
              let action = try? SegmentAction(dto: .playAudio(dto)),
              case .playAudio(let audio) = action else { return }
        let from = elapsed <= Self.areaLoopStartTolerance ? 0 : elapsed
        if !audioManager.playForAreaLoop(audio, elapsed: from) {
            logger.info("[explore] '\(occurrence.channel)' keeps its own clock: it cannot start \(String(format: "%.2f", from))s in")
        }
    }

    private func startLoopedVideo(_ occurrence: StoryRegionLoopOccurrence, elapsed: TimeInterval) {
        guard case .playVideo(let dto) = occurrence.opening else { return }
        let channel = occurrence.channel
        let from = elapsed <= Self.areaLoopStartTolerance ? 0 : elapsed
        let sourceTime = max(0, dto.sourceIn ?? 0) + from
        if !dto.loop, let out = dto.sourceOut, sourceTime >= out {
            // Its part of this loop is already over.
            return
        }
        let showing = areaLoopMedia?.videoOnChannel[channel] == occurrence.actionId
            && videoManager.playRequestedChannelNames.contains(channel)
        if showing {
            // A clip that loops on its own keeps its own loop past its start.
            if dto.loop && from > 0 { return }
            // The same clip is on this Screen: seek, then make sure it runs
            // (one that reached its end has stopped by itself). The engine's
            // own seek uses this same pair (`alignToSeek`).
            videoExecutor.seek(channel: channel, to: sourceTime)
            if videoManager.pauseForExploreHold(channel: channel) {
                videoManager.releaseExploreHold(channel: channel, resume: !sequenceEngine.isPaused)
            }
            return
        }
        guard let action = try? SegmentAction(dto: .playVideo(dto)),
              case .playVideo(let video) = action else { return }
        videoExecutor.play(video)
        if from > 0, !dto.loop { videoExecutor.seek(channel: channel, to: sourceTime) }
        areaLoopMedia?.videoOnChannel[channel] = occurrence.actionId
    }

    // MARK: - Sequence control

    /// Start playback of a named sequence. If another sequence is already
    /// running it is stopped first. Awaits any required immersive-space
    /// transition (`.immersive` sequence wants the space open,
    /// `.windowed` wants it dismissed) before the sequence's first segment
    /// runs so the engine never fires audio / video against a
    /// mis-presented stage.
    /// ONE PERFORMER. `ExperienceNavigator` decides where to go; this is the
    /// only thing that starts a Sequence, so the immersive-space transition and
    /// the skybox-registration wait below cannot be bypassed by a second entry
    /// path. `startingAtSegmentIndex` is non-zero only for a resumed visit.
    public func playSequence(_ sequence: SequenceDefinition,
                             startingAtSegmentIndex startIndex: Int = 0) async {
        await enterSequence(sequence, startingAtSegmentIndex: startIndex)
    }

    /// The performer itself. Returns false when it stopped without starting
    /// the Sequence because a host Play canceled the engine navigation it was
    /// carrying out (OD-111).
    @discardableResult
    private func enterSequence(_ sequence: SequenceDefinition,
                               startingAtSegmentIndex startIndex: Int) async -> Bool {
        // A HOST PLAY WINS (OD-111, owner decision): called by a host (never
        // inside an engine navigation's Task), this cancels an engine Go To
        // or ending still in flight, and proceeds.
        cancelEngineNavigationForHost()
        // COUNTED HERE, THE ONE PERFORMER EVERY ENTRY GOES THROUGH (OD-46):
        // a host's Play (MaestroVision calls this directly, never `navigate`),
        // `perform(.enter)` and the QA seams. While it waits on the space,
        // the scene and the skybox, an engine Go To or completion is dropped
        // rather than racing it. An engine navigation's slot already counts
        // it. The slot is released with no suspension after
        // `sequenceEngine.play`, so the new Sequence's own t=0 Go To is still
        // accepted.
        let counted = countNavigation()
        defer { if counted { navigationsInFlight -= 1 } }
        guard mayProceed else { return false }
        // A NEW SEQUENCE IS PLAYING, so no earlier ending is still deciding.
        heldStoryDecision = nil
        // A HOST THAT JUMPS STRAIGHT INTO A SEQUENCE still gets a session, so
        // its Story States hold their authored initial values rather than being
        // undefined. Guarded on the session FLAG, not on emptiness: a Chapter
        // that defines no Story State still has a session, and re-seeding on
        // every entry would reset the memory on the first Go To.
        if !storyState.isSessionActive { beginChapterPlaybackSession() }
        await applySequencePresentation(sequence)
        guard mayProceed else { return false }
        // THE SCENE EXISTS BEFORE ANYTHING IS ASKED OF IT. The same race as
        // the skybox wait below, one level up: a host that plays as soon as
        // it has opened (an autoplaying Chapter, a Play pressed while the
        // space is still coming up) reached the engine with nothing
        // registered. Every action at t=0 then named an entity that "did not
        // exist", was logged and dropped, and what it should have revealed
        // stayed hidden for the rest of the Sequence. Bounded: a host with no
        // immersive scene at all (windowed) is not held up for long.
        // ONLY WHILE A SPACE IS COMING UP. `applySequencePresentation` has just
        // returned with the space open, and the scene root mounts a beat after
        // that. A host with no immersive space (a windowed player, a test) is
        // never going to build a scene, and must not be made to wait for one.
        if immersiveSpaceState == .open,
           currentDocumentForStyling()?.entities.isEmpty == false, !documentEntities.hasMaterialized {
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline, !documentEntities.hasMaterialized, mayProceed {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            logger.info("[scene] materialize wait finished (built=\(self.documentEntities.hasMaterialized))")
        }
        guard mayProceed else { return false }
        // The FIRST play of a session races the ImmersiveSpace open:
        // openSpace returns when the system creates the scene, but the
        // consumer's RealityView registers the skybox shell a beat later
        // — and a backdrop dispatched into an empty registry gives up
        // ("skybox NOT registered" → black surround until the next play).
        // Wait briefly for registration before binding the backdrop.
        if sequence.presentation == .immersive, sequence.immersiveBackdrop != nil,
           videoManager.videoEntityRegistry["skybox"] == nil {
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline, videoManager.videoEntityRegistry["skybox"] == nil, mayProceed {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            logger.info("[backdrop] skybox registration wait finished (registered=\(self.videoManager.videoEntityRegistry["skybox"] != nil))")
        }
        // THE LAST CHECK, with no suspension between it and the start below:
        // a canceled engine navigation never starts its Sequence.
        guard mayProceed else { return false }
        commitEngineNavigation()
        applySequenceBackdrop(sequence)
        // SEQUENCE-LOCAL REST: place this sequence's objects where IT
        // stages them (and return anything the previous sequence placed
        // to its Chapter rest) before the first frame plays.
        entityExecutor.applyRestPlacements(sequence.restPlacements)
        // SEQUENCE-LOCAL PANEL STYLE: the style twin of the line above —
        // corner radius / spatial presentation / passthrough tinting as
        // THIS sequence presents them, before the first frame plays. The
        // DTO is resolved from the current document (the editor overrides
        // `currentDocumentForStyling`, same reason as
        // `sequenceFromLoadedDocument`: its edits never reach the frozen
        // load-time snapshot).
        if let document = currentDocumentForStyling(),
           let dto = document.sequences.first(where: { $0.id == sequence.id }) {
            applyPanelStyles(for: dto, in: document)
        }
        sequenceEngine.play(sequence: sequence, startingAtSegmentIndex: startIndex)
        return true
    }

    /// The document panel styling resolves against — the load-time snapshot
    /// by default; an editor host with a live synced copy overrides.
    open func currentDocumentForStyling() -> ChapterDocument? {
        loadedExperience?.document
    }

    /// The resolver the scene is built with: the load-time one by default; an
    /// editor host with on-device media overrides.
    open func currentMediaResolver() -> MediaResolver? {
        loadedExperience?.mediaResolver
    }

    /// Apply a sequence's panel-style overrides (`SequenceDefinitionDTO
    /// .panelStyles`) to the live entities — and, symmetrically, RETURN any
    /// panel the previous sequence styled to its Chapter spec. The resolved
    /// values ride on `VideoPanelStyleComponent`, which is where the video
    /// manager reads style at bind time; a plane already bound regenerates
    /// its mesh in place, exactly as an editor's live corner-radius slider
    /// does. Recomputed from the CHAPTER BASE each entry, so entering a
    /// sequence with no override restores the default by construction.
    /// `document` defaults to the loaded experience's; an editor host whose
    /// live document lives elsewhere (MaestroVision's synced copy) passes
    /// its own.
    public func applyPanelStyles(for sequence: SequenceDefinitionDTO,
                                 in explicitDocument: ChapterDocument? = nil) {
        guard let document = explicitDocument ?? loadedExperience?.document else { return }
        for definition in document.entities {
            let base: PanelStyleOverride
            if let panel = definition.videoPanel {
                base = PanelStyleOverride(
                    cornerRadius: panel.cornerRadius,
                    spatialPresentation: panel.spatialPresentation,
                    passthroughTinting: panel.passthroughTinting)
            } else if let placeholder = definition.placeholder,
                      placeholder.role == .videoPanel {
                base = PanelStyleOverride(cornerRadius: placeholder.cornerRadius)
            } else {
                continue
            }
            guard let entity = entityExecutor.entityRegistry[definition.id] else { continue }
            let resolved = sequence.panelStyle(for: definition.id, base: base)
            let radius = resolved.cornerRadius ?? 0
            var component = entity.components[VideoPanelStyleComponent.self]
                ?? VideoPanelStyleComponent(cornerRadius: 0,
                                            spatialPresentation: .flat,
                                            passthroughTinting: false)
            let radiusChanged = component.cornerRadius != radius
            component.cornerRadius = radius
            component.spatialPresentation = resolved.spatialPresentation ?? .flat
            component.passthroughTinting = resolved.passthroughTinting ?? false
            entity.components.set(component)
            // A bound panel regenerates its plane immediately; an unbound
            // one picks the component up when the manager binds it.
            if radiusChanged, var model = entity.components[ModelComponent.self] {
                let extents = model.mesh.bounds.extents
                if extents.x > 0.01, extents.y > 0.01 {
                    model.mesh = .generatePlane(
                        width: extents.x, height: extents.y,
                        cornerRadius: min(radius, min(extents.x, extents.y) / 2))
                    entity.components.set(model)
                }
            }
        }
    }

    /// APPLY ONE CONTINUATION BEHAVIOR, using the playback the runtime already
    /// has.
    ///
    /// Explore is an ORCHESTRATION layer: it starts and stops behavior that
    /// already exists, and never becomes a second media engine. That is why
    /// there is no loop implementation here — a clip authored to loop keeps
    /// looping under `.continue` through `AVPlayerLooper`, which is the
    /// primitive the runtime already trims to the source window.
    private func applyStoryContinuation(
        target: StoryContinuationTarget,
        behavior: StoryContinuationBehavior,
        phase: StoryRegionController.ContinuationPhase
    ) {
        // Everything a hold pauses is released in ONE place, `releaseStoryHolds`,
        // which the controller calls however the hold ends. Undoing it here
        // would only cover the path where the exit resolved.
        guard phase == .enteringHold else { return }

        switch target {
        case .entityAnimation:
            // An entity animation loop is handled by the sampling overlay.
            return

        case .backdropCue(let cueId):
            applyBackdropContinuation(cueId: cueId, behavior: behavior)

        case .occurrence(let actionId):
            guard let channel = channelForOccurrence(actionId) else {
                logger.warning("[explore] continuation target '\(actionId)' resolves to no channel — ignoring")
                return
            }
            let isVideo = isVideoOccurrence(actionId)
            let content: StoryHoldPlan.Content = isVideo ? .video : .audio
            // A LOOPING Area (OD-25, OD-99): media loops with it unless its
            // own continuation opts out. A play-once Area keeps the table.
            let plan: StoryHoldPlan.Command
            if let region = storyRegions.active?.region, region.playbackMode == .loop {
                plan = StoryHoldPlan.areaLoopCommand(
                    for: behavior,
                    exitFade: region.authoredContinuation(for: target)?.exitFade,
                    on: content)
            } else {
                plan = StoryHoldPlan.command(for: behavior, on: content)
            }
            switch plan {
            case .pause:
                // HOLD. Pause where the authored pass left it; a clip that
                // already ended is already showing its last frame.
                if isVideo {
                    if videoManager.pauseForExploreHold(channel: channel) {
                        storyHeldVideoChannels.insert(channel)
                    }
                } else if audioExecutor.pauseForExploreHold(channel: channel) {
                    // PER-CHANNEL, never `pauseAll()`, which would silence
                    // channels the author asked to keep playing.
                    storyHeldAudioChannels.insert(channel)
                }
            case .stop:
                if isVideo { videoExecutor.stop(channel: channel) }
                else { audioExecutor.stop(channel: channel) }
            case .leaveRunning:
                // Continuing means the content keeps running on its own clock
                // while authored time is parked, which it is already doing.
                break
            case .loopWithArea:
                // The Area's loop restarts it at its place in each loop
                // (`advanceAreaLoop`); nothing to do as the hold begins.
                break
            case .refuse(let reason):
                logger.warning("[explore] '\(channel)' keeps playing: \(reason)")
            }
        }
    }

    /// Video channels this hold froze, and audio channels it paused — so the
    /// release undoes exactly what the hold did and nothing else.
    @ObservationIgnored private var storyHeldVideoChannels: Set<String> = []
    @ObservationIgnored private var storyHeldAudioChannels: Set<String> = []

    /// AN ENVIRONMENT CUE, DURING A HOLD.
    ///
    /// The cue driver runs on the authored clock, so a parked story already
    /// keeps the same cue on screen. What a hold can add is freezing an
    /// Environment VIDEO, which runs on its own player: the same per-channel
    /// pause a video occurrence uses, on the one channel a backdrop has. An
    /// image or a USDZ Environment is already still, so Hold is trivially
    /// true for it.
    ///
    /// Applies only to the cue that is actually showing at the boundary. A
    /// policy for any other cue applies to nothing, and says so.
    private func applyBackdropContinuation(cueId: String, behavior: StoryContinuationBehavior) {
        guard backdropCues.activeCueID == cueId else {
            logger.info("[explore] Environment cue '\(cueId)' is not showing at the boundary — its policy applies to nothing")
            return
        }
        switch StoryHoldPlan.command(for: behavior, on: .backdrop) {
        case .pause:
            if videoManager.pauseForExploreHold(channel: Self.backdropVideoChannel) {
                storyHeldVideoChannels.insert(Self.backdropVideoChannel)
            }
        case .leaveRunning, .loopWithArea:
            break
        case .stop, .refuse:
            logger.warning("[explore] Environment cue '\(cueId)' keeps playing: \(StoryHoldPlan.backdropStopRefusal)")
        }
    }

    /// THE DEFAULT, for content the author said nothing about.
    ///
    /// A region owns no clip, so it cannot list what is playing — the player
    /// can. Video holds its last frame by default (`docs/STORY_REGIONS.md`
    /// §6); an absent continuation used to do nothing at all here, so the
    /// documented default kept playing on device while the Sequence clock
    /// stood still, and came back out of sync with its own Timeline.
    ///
    /// A LOOPING Area pauses nothing by default: video and sound nobody
    /// configured loop with it instead (OD-25), restarted by
    /// `advanceAreaLoop`.
    private func applyDefaultStoryHold(for region: StoryRegion) {
        guard region.playbackMode == .playOnce else { return }
        var configured: Set<String> = []
        for continuation in region.continuations {
            if case .occurrence(let actionId) = continuation.target,
               let channel = channelForOccurrence(actionId) {
                configured.insert(channel)
            }
        }
        let held = StoryHoldPlan.videoChannelsHeldByDefault(
            playing: videoManager.playRequestedChannelNames,
            explicitlyConfigured: configured,
            protected: videoManager.protectedChannels
        )
        for channel in held where videoManager.pauseForExploreHold(channel: channel) {
            storyHeldVideoChannels.insert(channel)
        }
    }

    /// The hold ended — resolved, interrupted, passed or torn down. Release
    /// everything it paused. While the transport itself is paused the hold
    /// still ends, and `resumeAll()` restarts the players.
    private func releaseStoryHolds() {
        let resume = !sequenceEngine.isPaused
        for channel in storyHeldVideoChannels {
            videoManager.releaseExploreHold(channel: channel, resume: resume)
        }
        for channel in storyHeldAudioChannels {
            audioExecutor.releaseExploreHold(channel: channel, resume: resume)
        }
        storyHeldVideoChannels.removeAll()
        storyHeldAudioChannels.removeAll()
        areaLoopMedia = nil
    }

    /// FADE THIS CONTENT OUT AS THE STORY RESUMES.
    ///
    /// Applied on the way out of a hold, using the per-channel gain command
    /// that has existed since long before Story Regions — the region owns no
    /// gain engine of its own. Audio only, which is the only place
    /// `StoryContinuationCapabilities` offers it.
    private func applyStoryExitFade(target: StoryContinuationTarget, seconds: TimeInterval) {
        guard case .occurrence(let actionId) = target,
              let channel = channelForOccurrence(actionId),
              !isVideoOccurrence(actionId) else { return }
        logger.info("[explore] fading '\(channel)' out over \(String(format: "%.2f", seconds))s on exit")
        audioExecutor.fade(channel: channel, to: 0, duration: seconds)
    }

    /// Is this occurrence a video? Video and audio share `channelForOccurrence`
    /// but not a single executor, and sending one's command to the other is how
    /// audio "hold" came to be a control that did nothing.
    private func isVideoOccurrence(_ actionId: String) -> Bool {
        guard let document = loadedExperience?.document else { return false }
        for sequence in document.sequences {
            for segment in sequence.segments {
                for authored in segment.authoredActions where authored.id == actionId {
                    switch authored.action {
                    case .playVideo, .prepareVideo: return true
                    default: return false
                    }
                }
            }
        }
        return false
    }

    /// The playback channel one authored occurrence plays on.
    ///
    /// Resolved from the DOCUMENT by stable action id, never from a filename or
    /// an index — an occurrence keeps its id through trim, slip, blade and
    /// retime, so a continuation override survives all of them.
    private func channelForOccurrence(_ actionId: String) -> String? {
        guard let document = loadedExperience?.document else { return nil }
        for sequence in document.sequences {
            for segment in sequence.segments {
                for authored in segment.authoredActions where authored.id == actionId {
                    switch authored.action {
                    case .playVideo(let v), .prepareVideo(let v): return v.channel
                    case .playAudio(let a): return a.channel
                    default: return nil
                    }
                }
            }
        }
        return nil
    }

    /// OFFER ONE SEMANTIC ACTIVATION TO THE WAITING GATE.
    ///
    /// The gate decides for itself whether this activation is the one it is
    /// waiting for — shared input, distinct consumers. The DECISION is
    /// `ChapterScript.GateActivation`, not a rule of this file's own: it
    /// determines whether a story advances, which is not something to discover
    /// on a headset. Sensing happens here; deciding does not.
    ///
    /// Returns true when the gate was satisfied.
    private func offerActivationToGate(
        entityName: String?, trigger: InteractionTrigger,
        interactionRan: Bool, isAccessible: Bool = false
    ) -> Bool {
        let activation = SemanticActivation(
            entityName: entityName, trigger: trigger,
            interactionRan: interactionRan, isAccessible: isAccessible)

        // A WAITING CHOICE HEARS IT FIRST (OD-8). A tap or look-and-pinch on
        // one of its buttons, or an act on an Object an option names, is a
        // pick; any other act does not answer a Choice
        // (`GateActivation.satisfies` refuses it below).
        if sequenceEngine.isWaiting, let gate = sequenceEngine.currentGate {
            let authored = authoredGate(for: gate)
            if GateActivation.waitsForChoice(authored) {
                if let optionId = choices.optionId(forEntityName: entityName) {
                    return pickChoiceOption(optionId)
                }
                if let option = GateActivation.choiceOption(for: authored, activation: activation,
                                                            state: storyState.ledger) {
                    return pickChoiceOption(option.optionId)
                }
            }
        }

        // THE WAITING CUE HEARS IT FIRST. One act, one Cue: an act that
        // releases the Cue the story is waiting at is spent there.
        if sequenceEngine.isWaiting, let gate = sequenceEngine.currentGate,
           // THE ACT **AND** WHAT THE STORY REMEMBERS. A condition an author
           // added to a gate is a requirement, so "tap the door once you have
           // the key" cannot be opened by the tap alone.
           GateActivation.satisfies(gate: authoredGate(for: gate), activation: activation,
                                    state: storyState.ledger) {
            logger.info("[gate] satisfied by \(isAccessible ? "an accessible" : "a physical") \(trigger.kindName) activation on '\(entityName ?? "—")'")
            sequenceEngine.satisfyGate()
            return true
        }

        // EARLY ACTS COUNT FROM AREA ENTRY (OD-23). While an Explore Area's
        // first pass plays, the act its exit asks for finishes the Area now,
        // so the story does not stall at its end. The Area judges it by the
        // same rule (`StoryRegionRuntime.acceptsEarlyExit`), with its exit
        // timing (OD-121: by default a plain tap counts only while waiting);
        // at its boundary it declines, because there the exit is the waiting
        // Cue above. An act a Cue spent a moment ago answers nothing else.
        if storyRegions.offerEarlyExit(activation, state: storyState.ledger,
                                       answeredACue: actWasJustSpentOnACue(activation)) {
            logger.info("[explore] Area exit satisfied early by \(isAccessible ? "an accessible" : "a physical") \(trigger.kindName) activation on '\(entityName ?? "—")'")
            return true
        }
        return false
    }

    // MARK: - The authored Cue

    /// THE CUE AS AUTHORED, from the document, for the gate the engine is
    /// waiting at. The engine's runtime mirror (`SegmentGate.authored`)
    /// carries only what the engine itself needs and leaves out the Choice
    /// (OD-8), so every question about a waiting Cue asks this instead: a
    /// Choice Cue read through the mirror looked like a plain tap Cue that
    /// any tap continued. Falls back to the mirror when the document has no
    /// matching Cue (a host that plays a Sequence the document lacks).
    func authoredGate(for gate: SegmentGate) -> SegmentGateDTO {
        guard let sequenceId = sequenceEngine.currentSequence?.id,
              let sequence = currentDocumentForStyling()?.sequences.first(where: { $0.id == sequenceId })
        else { return gate.authored }
        let index = sequenceEngine.currentSegmentIndex
        guard sequence.segments.indices.contains(index),
              let authored = sequence.segments[index].gate,
              authored.type == gate.type.authored,
              authored.prompt == gate.prompt,
              authored.targetEntity == gate.targetEntity
        else { return gate.authored }
        return authored
    }

    // MARK: - The viewer-facing Choice (OD-8)

    /// The story began waiting at a Choice Cue: show its question and options.
    private func beginChoiceWait(_ gate: SegmentGateDTO) {
        choiceWait = ChoiceWait(gate: gate, visit: activeVisitID,
                                sequenceId: sequenceEngine.currentSequence?.id,
                                segmentIndex: sequenceEngine.currentSegmentIndex,
                                began: sequenceEngine.totalElapsed)
        let definitions = currentDocumentForStyling()?.storyState ?? []
        choices.show(ChoicePlan.plan(for: gate, definitions: definitions))
        // An option that names an Object can be picked by acting on it, so
        // the Object offers that option to assistive technology too.
        for option in gate.choice?.options ?? [] {
            guard let target = option.targetEntity, !target.isEmpty,
                  let choice = gate.choice else { continue }
            interactions.setGateAction(
                entityName: target,
                label: choice.displayLabel(
                    for: option,
                    definition: choice.stateId.flatMap { id in definitions.first { $0.id == id } }),
                trigger: .tap)
        }
    }

    /// The Choice Cue resolved however it did: picked, timed out, stopped or
    /// seeked past. Hides the options; a timeout with nobody picking takes
    /// the Choice's timeout option, when it has one.
    private func endChoiceWait() {
        guard let wait = choiceWait else { return }
        choiceWait = nil
        choices.hide()
        guard !wait.picked, let timeout = wait.gate.timeout,
              let resolution = wait.gate.choice?.resolveTimeout() else { return }
        // THE ENGINE'S TIMER RELEASED IT, not a stop or a seek: the engine is
        // still playing and unpaused (its timer never fires while paused),
        // and the wait lasted the timeout on the pause-aware clock.
        guard sequenceEngine.isPlaying, !sequenceEngine.isPaused,
              sequenceEngine.totalElapsed - wait.began >= timeout - 0.05 else { return }
        logger.info("[choice] the Cue timed out; taking its timeout option '\(resolution.option.optionId, privacy: .public)'")
        if let mutation = resolution.mutation { storyState.apply(mutation) }
        if let path = resolution.path {
            startEngineNavigation("a Choice's timeout Path") {
                self.storyRegions.teardown()
                await self.navigate(path, source: .host)
            }
        }
    }

    /// THE VIEWER PICKED AN OPTION (OD-8). The one route every picker takes:
    /// a button tapped or looked at and pinched, a VoiceOver Activate, an
    /// act on an Object an option names, a host or a test.
    ///
    /// The resolution is ChapterScript's (`GateActivation.pick`): the Cue's
    /// Memory conditions must hold, and the option must be one of its own.
    /// Then, in this order: the Memory records what was chosen, the options
    /// go, and the option's Path is followed through the one navigator (a
    /// Path that goes nowhere, or no Path, continues the Cue here).
    ///
    /// Returns true when the pick was taken.
    @discardableResult
    public func pickChoiceOption(_ optionId: String) -> Bool {
        guard sequenceEngine.isWaiting, let gate = sequenceEngine.currentGate,
              var wait = choiceWait, !wait.picked else { return false }
        let authored = authoredGate(for: gate)
        let resolution: CueChoiceResolution
        switch GateActivation.pick(optionId, on: authored, state: storyState.ledger) {
        case .success(let resolved):
            resolution = resolved
        case .failure(let refusal):
            logger.info("[choice] pick '\(optionId, privacy: .public)' refused: \(String(describing: refusal), privacy: .public)")
            return false
        }
        wait.picked = true
        choiceWait = wait
        let answered = wait
        choices.hide()
        logger.info("[choice] the viewer picked '\(optionId, privacy: .public)'")
        // MEMORY FIRST, so a Path that is itself a branch on this Memory
        // already sees the pick.
        if let mutation = resolution.mutation { storyState.apply(mutation) }
        guard let path = resolution.path else {
            sequenceEngine.satisfyGate()
            return true
        }
        let source = NavigationSource.interaction(entity: authored.targetEntity ?? "",
                                                  interactionId: optionId)
        let started = startEngineNavigation("a Choice's Path") {
            self.storyRegions.teardown()
            await self.navigate(path, source: source)
            // A Path that went nowhere (a branch with no match, a refusal)
            // leaves the story at this Cue; the pick still answered it.
            if self.isStillWaiting(at: answered) { self.sequenceEngine.satisfyGate() }
        }
        if !started {
            // Another navigation holds the slot (OD-46): the pick is recorded
            // and the Cue continues here rather than leaving the story stuck.
            logger.info("[choice] the Path was dropped: another navigation is in progress")
            sequenceEngine.satisfyGate()
        }
        return true
    }

    /// Is the story still waiting at the Choice Cue `wait` describes?
    private func isStillWaiting(at wait: ChoiceWait) -> Bool {
        sequenceEngine.isWaiting
            && activeVisitID == wait.visit
            && sequenceEngine.currentSequence?.id == wait.sequenceId
            && sequenceEngine.currentSegmentIndex == wait.segmentIndex
    }

    // MARK: - Comfort (OD-50)

    /// CARRY OUT WHAT A COMFORT SIGNAL ASKS (OD-50, owner decision). The
    /// system paused or shrank video for comfort: the whole story pauses
    /// with it, through the transport's own `pause()`, and a short calm
    /// message says so. The system resumed playback: a story this paused
    /// resumes. Very high heat: a warning only, nothing pauses.
    ///
    /// Never resumes a pause the person made, and never pauses a story that
    /// is not playing.
    public func handleComfortResponse(_ response: ComfortSignals.Response) {
        switch response {
        case .pauseStory(let message):
            guard sequenceEngine.isPlaying, !sequenceEngine.isPaused else { return }
            sequenceEngine.pause()
            isStoryPausedForComfort = true
            comfortNotice.show(message)
            logger.info("[comfort] the story paused with the system's comfort pause")
        case .resumeStory:
            guard isStoryPausedForComfort else { return }
            isStoryPausedForComfort = false
            // The person may have resumed, or stopped, in the meantime.
            if sequenceEngine.isPlaying, sequenceEngine.isPaused { sequenceEngine.resume() }
            comfortNotice.show(comfortSignals.activeWarning)
            logger.info("[comfort] the story resumed with the system")
        case .showWarning(let message):
            // A comfort pause's message stays up; the warning shows when it goes.
            guard !isStoryPausedForComfort else { return }
            comfortNotice.show(message)
        case .clearWarning:
            guard !isStoryPausedForComfort else { return }
            comfortNotice.hide()
        }
    }

    /// The story is no longer paused, but not because the system resumed:
    /// the person did. The comfort pause is over, and its message goes (a
    /// heat warning still in force comes back).
    private func comfortPauseEndedElsewhereIfResumed() {
        guard isStoryPausedForComfort, !sequenceEngine.isPaused else { return }
        isStoryPausedForComfort = false
        comfortNotice.show(comfortSignals.activeWarning)
    }

    // MARK: - Performing navigation

    /// Carry out ONE navigation outcome. The only place a Sequence starts.
    ///
    /// The navigator decided; this performs. Presentation and backdrop are
    /// applied here because crossing a Sequence boundary is exactly where an
    /// immersive → windowed transition fires and where the previous Sequence's
    /// environment is torn down before the new one binds — which the old
    /// inline chain-walker also did, and which is the behavior old Chapters
    /// depend on.
    @MainActor
    public func perform(_ outcome: NavigationOutcome) async {
        switch outcome {
        case .enter(let sequenceId, let visit, let resumingFrom):
            guard let next = sequenceFromLoadedDocument(id: sequenceId) else {
                logger.warning("[flow] '\(sequenceId)' vanished between decision and entry")
                return
            }
            // Put the visit we are leaving aside before `playSequence` tears it
            // down, so a later Resume can hand it back.
            if let outgoing = activeVisitID {
                visitLedgers[outgoing] = interactions.ledgerSnapshot
            }
            // DELEGATES TO THE ONE PERFORMER rather than starting the engine
            // itself. `playSequence` owns the immersive-space transition and
            // the skybox-registration wait, and a second start path that
            // skipped them is exactly the class of divergence this pass exists
            // to remove.
            //
            // RESUME ENTERS AT AN AUTHORED POSITION; a fresh visit starts at
            // the beginning. Restart and Resume must never share an
            // implementation ACCIDENTALLY — they share this one deliberately,
            // because entering is entering, and they differ in the VISIT the
            // navigator handed back.
            let startIndex = resumingFrom.map { segmentIndex(of: next, atAuthoredTime: $0) } ?? 0
            // Read now: the navigator's answer belongs to the request that
            // produced this outcome.
            let memoryToRestore = resumingFrom != nil ? navigator.restoredMemorySnapshot : nil
            // A host Play that canceled this (engine) navigation while it
            // waited on the space or the scene has already won (OD-111):
            // nothing of this visit is recorded.
            guard await enterSequence(next, startingAtSegmentIndex: startIndex) else { return }

            // RESUME RESTORES THE MEMORY THE VISIT WAS LEFT WITH (OD-98,
            // owner decision). After the start, so the visit that was left
            // is already stopped and cannot react to it, and before the
            // resumed visit's segment loop first runs (its Task starts after
            // this turn), so its Cues and branches read what the viewer had
            // when they left. Entry counters are kept: a Return is an entry,
            // and a counter counts the whole run. Only a Resume carries a
            // snapshot; a Restart or a fresh visit leaves Memory as it stands.
            if let memoryToRestore {
                let counters = Set((currentDocumentForStyling()?.storyState ?? [])
                    .filter { $0.countsEntriesOfSequenceId != nil }
                    .map(\.id))
                storyState.restore(memoryToRestore, keeping: counters)
            }

            // ── WHAT A VISIT OWNS, RESTORED OR RE-ARMED ─────────────────────
            //
            // `playSequence` always re-arms. For a fresh visit that is correct
            // and this changes nothing. For a RESUMED one it is the bug: the
            // audience comes back to a Sequence where everything they had
            // already done is undone. Resume is the one case that carries a
            // position, and it is the one case that restores.
            activeVisitID = visit.id
            if resumingFrom != nil, let restored = visitLedgers[visit.id] {
                interactions.restoreLedger(restored)
            } else {
                visitLedgers[visit.id] = nil
            }
            pruneVisitLedgers()

        case .finish:
            heldStoryDecision = nil
            sequenceEngine.stop()
            comfortPauseEndedElsewhereIfResumed()
            activeSequenceId = nil
            activeVisitID = nil
            visitLedgers.removeAll()
            // THE RUN IS OVER, so the session's memory ends with it. Nothing is
            // carried into the next run — that is what "a new playback session
            // resets Story State" means from the other side.
            storyState.endSession()

        case .stay:
            break

        case .refused(let refusal):
            // REFUSED, NOT REDIRECTED. Silently going somewhere plausible is
            // how an audience ends up in the wrong part of a story with no
            // trace of why.
            logger.warning("[flow] navigation refused: \(refusal.message)")
        }
    }

    /// Ask the navigator to do something, then do it.
    @MainActor
    public func navigate(_ intent: NavigationIntent, source: NavigationSource = .host) async {
        // A host's own request wins over an engine navigation in flight (OD-111).
        cancelEngineNavigationForHost()
        let counted = countNavigation()
        defer { if counted { navigationsInFlight -= 1 } }
        guard mayProceed else { return }
        // `.start` IS THE BEGINNING OF A CHAPTER PLAYBACK SESSION. Seeding here
        // rather than inside the navigator keeps the navigator pure, and keeps
        // the one thing that resets Story State at the one place a Chapter
        // begins.
        if case .start = intent { beginChapterPlaybackSession() }

        let outcome = navigator.handle(
            NavigationRequest(intent: intent, source: source),
            exists: { self.sequenceFromLoadedDocument(id: $0) != nil },
            start: { self.loadedExperience?.document.defaultSequenceId },
            currentPosition: sequenceEngine.sequenceAnimationTime,
            // A BRANCH IS RESOLVED AGAINST THE RUNNING SESSION, by the shared
            // evaluator. Nothing here decides which case wins.
            storyState: storyState.ledger,
            // OD-98: the Memory of the visit this request leaves goes with it.
            memorySnapshot: storyState.memorySnapshot)
        await perform(outcome)
    }

    /// BEGIN A CHAPTER PLAYBACK SESSION. Every Story State returns to its
    /// authored initial value.
    ///
    /// The ONLY thing that resets Story State. Deliberately not called from
    /// `playSequence`, which starts a Sequence VISIT: Go To, Return and Restart
    /// all run through that, and every one of them must leave the story's memory
    /// exactly as the audience left it.
    @MainActor
    public func beginChapterPlaybackSession() {
        storyState.beginSession(loadedExperience?.document.storyState ?? [])
    }

    /// The segment a resumed visit re-enters at.
    ///
    /// AUTHORED-BOUNDARY RESUME: playback resumes at the start of the segment the
    /// visit had reached, not at an arbitrary sub-second offset. Reconstructing
    /// exact mid-action runtime state (a video part-played, a fade half-run, a
    /// gate part-dwelt) would need a retained live graph per suspended visit,
    /// which an hour-long chapter cannot afford. Documented as such rather than
    /// faked — see `docs/EXPERIENCE_FLOW.md` §Resume.
    private func segmentIndex(of sequence: SequenceDefinition, atAuthoredTime time: TimeInterval) -> Int {
        var elapsed: TimeInterval = 0
        for (index, segment) in sequence.segments.enumerated() {
            elapsed += segment.duration
            if time < elapsed { return index }
        }
        return max(sequence.segments.count - 1, 0)
    }

    /// Arm the loaded document's interactions against the live scene.
    ///
    /// Document-wide, not Sequence-scoped — an interaction belongs to the
    /// object. Unrevealed objects are simply never hit: every watch checks that
    /// the entity is in the scene and enabled before it measures anything.
    public func installInteractions() {
        guard let document = loadedExperience?.document else { return }
        interactions.install(document: document)
    }

    /// Bind / swap / tear down the sequence's immersive backdrop. Called
    /// from the user-initiated play path and from auto-advance. No-op
    /// for `.windowed` sequences (the immersive space isn't open).
    /// Signature of the video backdrop currently bound (nil = none).
    /// Drives the replay fast path below.
    private static var lastVideoBackdropSignature: String? {
        get { _lastVideoBackdropSignatureStore }
        set { _lastVideoBackdropSignatureStore = newValue }
    }

    /// What makes two video backdrops THE SAME MOUNT, for the replay fast
    /// path below. The source window has been part of it since two cuts of
    /// one file turned out to be two backdrops; the EFFECT STACK is part of
    /// it for the same reason and a sharper one — a graded backdrop is
    /// mounted as a mesh and an ungraded one as a component, so replaying
    /// one as the other would seek a player whose pixels go nowhere.
    private static func videoBackdropSignature(
        file: String, layout: VideoLayout, field: ImmersiveField, radius: Float,
        loop: Bool, audioEnabled: Bool, sourceRange: MediaSourceRange,
        effects: [EffectInstance]?
    ) -> String {
        let stack = (effects ?? [])
            .map { "\($0.id):\($0.effectId):\($0.enabled)" }
            .joined(separator: ",")
        return "\(file)|\(layout)|\(field)|\(radius)|\(loop)|\(audioEnabled)"
            + "|\(sourceRange.resolvedIn)|\(String(describing: sourceRange.sourceOut))|\(stack)"
    }

    /// Apply the backdrop showing at the START of `sequence`.
    ///
    /// Cue zero, not "the sequence's backdrop" — with a track authored, the
    /// sequence does not have ONE backdrop, and `BackdropCueDriver` takes over
    /// from here to follow the rest. Kept as the entry point the play path
    /// already calls so the pre-track behavior is unchanged for documents
    /// with no cues.
    public func applySequenceBackdrop(_ sequence: SequenceDefinition) {
        let cue = SequenceBackdropTimeline.activeCue(
            at: 0,
            track: sequence.backdropTrack,
            legacy: sequence.immersiveBackdrop.map { ImmersiveBackdropSpec(runtime: $0) }
        )
        presentBackdrop(cue?.spec.flatMap { SequenceBackdrop($0) },
                        sourceRange: cue?.sourceRange ?? .full,
                        presentation: sequence.presentation,
                        effects: cue?.effects,
                        transform: cue?.resolvedTransform ?? .identity,
                        sequenceId: sequence.id)
    }

    public func presentBackdrop(
        _ spec: SequenceBackdrop?,
        sourceRange: MediaSourceRange,
        presentation: SequencePresentation,
        effects: [EffectInstance]?,
        transform: BackdropTransform
    ) {
        presentBackdrop(spec, sourceRange: sourceRange,
                        presentation: presentation, effects: effects,
                        transform: transform,
                        sequenceId: activeSequenceId ?? "")
    }

    /// Move the world. Position and rotation compose on the shell's rest
    /// transform; scale is written absolutely because the mounts already
    /// write it absolutely (the image path's interior mirror, the graded
    /// video path's mirrored mesh), and the mirror is preserved by sign.
    ///
    /// A graded video shell re-mirrors itself when its surface mounts,
    /// which can land after this call — that shell keeps the cue's position
    /// and rotation and returns to unit scale. Scale on an immersive plate
    /// is close to meaningless at its radius; the one that matters, USDZ,
    /// is written directly.
    private func applyBackdropPlacement() {
        let placement = currentBackdropTransform
        if let skybox = videoManager.videoEntityRegistry["skybox"] {
            let rest = skyboxRestTransform ?? {
                let rest = skybox.transform
                skyboxRestTransform = rest
                return rest
            }()
            skybox.position = rest.translation + placement.positionVector
            skybox.orientation = rest.rotation * placement.orientation
            let mirror: SIMD3<Float> = skybox.scale.x < 0 ? [-1, 1, 1] : .one
            skybox.scale = placement.scaleVector * mirror
        }
        if let usdz = currentBackdropUSDZ {
            usdz.position = placement.positionVector
            usdz.orientation = placement.orientation
            usdz.scale = placement.scaleVector
        }
    }

    /// Fade whatever backdrop is mounted. Both slots are written because either
    /// may be live — a video/image skybox and a USDZ backdrop mount to different
    /// entities, and the driver does not know (or want to know) which.
    ///
    /// `OpacityComponent` is the same mechanism `VideoPlaybackManager` uses to
    /// hold a cold video at zero until it is ready, so a backdrop fade costs no
    /// new machinery and behaves identically on device.
    public func setBackdropOpacity(_ opacity: Float) {
        let clamped = max(0, min(1, opacity))
        for entity in [videoManager.videoEntityRegistry["skybox"], currentBackdropUSDZ] {
            guard let entity else { continue }
            entity.components.set(OpacityComponent(opacity: clamped))
        }
    }

    private func presentBackdrop(
        _ backdropSpec: SequenceBackdrop?,
        sourceRange: MediaSourceRange,
        presentation sequencePresentation: SequencePresentation,
        effects: [EffectInstance]?,
        transform: BackdropTransform,
        sequenceId: String
    ) {
        // The placement is NOT part of the replay signature below: the same
        // plate turned differently is the same mount, moved — so a cue that
        // only re-places the world takes the fast path and is simply moved.
        currentBackdropTransform = transform
        lightIsTheWorlds = sequencePresentation == .immersive
        switch backdropSpec {
        case .image(let file, _, _)?: stillSurround = .image(file: file)
        case .usdz?: stillSurround = .model
        case .video?, nil: stillSurround = .room   // a video reports itself when it mounts
        }
        refreshSceneLight()
        logger.info("[backdrop] present sequence=\(sequenceId) presentation=\(String(describing: sequencePresentation)) backdrop=\(String(describing: backdropSpec))")
        // REPLAY FAST PATH — the single most important rule this pipeline
        // has learned on device: re-attaching a VideoPlayerComponent after
        // a stop strips it is FLAKY (same logs, sometimes renders,
        // sometimes ready-but-black). A replay of the IDENTICAL video
        // backdrop therefore never touches the component: verify the
        // live binding (same config, live player + item, skybox mounted
        // in a scene and still hosting its component) and just seek to
        // the start and play. Any mismatch or dead binding falls through
        // to the normal teardown + rebuild.
        if case .video(let file, let layout, let field, let radius, let loop, let audioEnabled)? = backdropSpec,
           sequencePresentation == .immersive,
           currentBackdropUSDZ == nil {
            // The source window is part of the signature: the same file cut
            // 0-6 and cut 20-26 are two different backdrops, and treating
            // them as identical would replay the first window for the second
            // cue.
            let signature = Self.videoBackdropSignature(
                file: file, layout: layout, field: field, radius: radius,
                loop: loop, audioEnabled: audioEnabled,
                sourceRange: sourceRange, effects: effects)
            if signature == Self.lastVideoBackdropSignature,
               let player = videoManager.player(for: Self.backdropVideoChannel),
               let item = player.currentItem, item.status != .failed,
               let skybox = videoManager.videoEntityRegistry["skybox"],
               skybox.scene != nil,
               skybox.components.has(VideoPlayerComponent.self) {
                skybox.isEnabled = true
                // Back to the WINDOW's start, not the file's.
                player.seek(to: CMTime(seconds: sourceRange.resolvedIn, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                applyBackdropPlacement()
                logger.info("[backdrop] REPLAY fast path: identical backdrop, live binding verified — seek+play, component untouched")
                return
            }
        }
        // THE SAME WORLD, PRESENTED AGAIN, IS MOVED.
        //
        // A Sequence start presents cue zero twice (the host, then the cue
        // driver's own synchronous apply), and every seek or Segment jump
        // presents it once more. Each used to tear the model down and load it
        // again; an environment is routinely hundreds of megabytes, so a
        // ruler tap cost seconds of nothing and the first play loaded it
        // twice. Mounted or still loading, the placement is what changed.
        if case .usdz(let assetId)? = backdropSpec,
           sequencePresentation != .windowed,
           assetId == backdropUSDZAssetId,
           immersiveSceneRoot != nil,
           currentBackdropUSDZ == nil || currentBackdropUSDZ?.parent === immersiveSceneRoot {
            applyBackdropPlacement()
            return
        }
        // First, drop whatever was bound for the previous sequence so
        // the new sequence starts from a clean slate.
        videoManager.stop(channel: Self.backdropVideoChannel)
        // A load in flight is now stale by definition — see the generation
        // note at the USDZ branch below.
        backdropUSDZGeneration &+= 1
        currentBackdropUSDZ?.removeFromParent()
        currentBackdropUSDZ = nil
        backdropUSDZAssetId = nil
        tearDownImageSkybox()

        // Backdrops only make sense for immersive / mixed sequences.
        Self.lastVideoBackdropSignature = nil
        // Nothing mounted yet, or nothing at all: the shell returns to its
        // rest before anything new is placed on it.
        currentBackdropTransform = backdropSpec == nil ? .identity : transform
        applyBackdropPlacement()
        guard sequencePresentation != .windowed, let backdrop = backdropSpec else {
            logger.info("[backdrop] nothing to apply (presentation=\(String(describing: sequencePresentation)), spec=\(backdropSpec == nil ? "nil" : "set"))")
            return
        }

        switch backdrop {
        case .video(let file, let layout, let field, let radius, let loop, let audioEnabled):
            // Video backdrop = stereoscopic-capable VideoPlayerComponent
            // wrapping the camera. Would block the user's mixed-reality
            // view, so reject in mixed mode.
            guard sequencePresentation == .immersive else {
                logger.info("Skipping video backdrop on \(String(describing: sequencePresentation)) sequence — would occlude passthrough.")
                return
            }
            logger.info("[backdrop] dispatching video backdrop file='\(file)' layout=\(String(describing: layout)) field=\(String(describing: field)) radius=\(radius) loop=\(loop) audio=\(audioEnabled)")
            Self.lastVideoBackdropSignature = Self.videoBackdropSignature(
                file: file, layout: layout, field: field, radius: radius,
                loop: loop, audioEnabled: audioEnabled,
                sourceRange: sourceRange, effects: effects)
            videoManager.play(action: VideoAction(
                file: file,
                channel: Self.backdropVideoChannel,
                volume: audioEnabled ? 1 : 0,
                loop: loop,
                presentation: .immersive(radius: radius, field: field),
                layout: layout,
                sourceIn: sourceRange.sourceIn,
                sourceOut: sourceRange.sourceOut,
                // FL-09: the cue's stack rides the play, exactly as an
                // occurrence's does. `VideoPlaybackManager` decides whether
                // this backdrop can be mounted as a graded mesh or has to
                // keep its component and say the stack is unrendered.
                effects: effects
            ))
            applyBackdropPlacement()

        case .image(let file, let field, let radius):
            // Static equirectangular image skybox. Same occlusion
            // concern as video — sphere wraps the user — so reject in
            // mixed mode.
            guard sequencePresentation == .immersive else {
                logger.info("Skipping image backdrop on \(String(describing: sequencePresentation)) sequence — would occlude passthrough.")
                return
            }
            bindImageSkybox(file: file, field: field, radius: radius, sequenceId: sequenceId)

        case .usdz(let assetId):
            // USDZ backdrops work in BOTH immersive and mixed modes —
            // a 3D set piece floating in space is fine over
            // passthrough.
            // Existence check only: the live root is re-read on completion
            // (see below), never captured here.
            guard immersiveSceneRoot != nil else {
                logger.warning("Backdrop USDZ '\(assetId)' skipped — immersive scene root not mounted.")
                return
            }
            guard let url = resolveBackdropAssetURL(file: assetId, kind: .usdz) else {
                logger.warning("Backdrop USDZ '\(assetId)' could not be located on disk.")
                return
            }
            // ONE LOAD WINS, AND IT INSTALLS INTO THE ROOT THAT IS CURRENT.
            //
            // The staleness guard here used to be `activeSequenceId ==
            // sequenceId`, which cannot see a RE-ENTRY into the same Sequence —
            // a Restart, or a Go To back to it. Both loads then passed, both
            // called `addChild`, and `currentBackdropUSDZ` kept only the
            // second: the first copy was stranded under the root with no
            // reference left to remove it. The generation counter answers
            // "is this still the load anyone asked for?", which is the actual
            // question.
            //
            // The root is also re-read on completion rather than captured at
            // dispatch: an immersive remount between the two would otherwise
            // install the backdrop into the torn-down scene.
            backdropUSDZGeneration &+= 1
            let generation = backdropUSDZGeneration
            backdropUSDZAssetId = assetId
            Task { @MainActor in
                do {
                    let entity = try await Entity(contentsOf: url)
                    // The generation IS the staleness test: every present and
                    // every teardown moves it. The Sequence id was checked here
                    // too, and a present stamped before the host learned the id
                    // failed it on a load nothing had superseded.
                    guard self.backdropUSDZGeneration == generation else { return }
                    guard let liveRoot = self.immersiveSceneRoot else {
                        logger.warning("Backdrop USDZ '\(assetId)' finished loading after the immersive root went away — discarding.")
                        return
                    }
                    // Anything a previous load installed goes first: this is
                    // the only reference to it that will ever exist.
                    self.currentBackdropUSDZ?.removeFromParent()
                    liveRoot.addChild(entity)
                    self.currentBackdropUSDZ = entity
                    self.applyBackdropPlacement()
                } catch {
                    if self.backdropUSDZGeneration == generation { self.backdropUSDZAssetId = nil }
                    logger.warning("Failed to load backdrop USDZ '\(assetId)': \(String(describing: error))")
                }
            }
        }
    }

    /// Build a sphere mesh + UnlitMaterial(texture:) on the skybox
    /// entity using the file as an equirectangular projection. Half-
    /// sphere for `.equirect180`, full sphere for `.equirect360`.
    private func bindImageSkybox(file: String, field: ImmersiveField, radius: Float, sequenceId: String) {
        guard let url = resolveBackdropAssetURL(file: file, kind: .image) else {
            logger.warning("Backdrop image '\(file)' could not be located on disk.")
            return
        }
        guard let skybox = videoManager.videoEntityRegistry["skybox"] else {
            logger.warning("Image backdrop has no 'skybox' entity registered.")
            return
        }
        // Every present and teardown moves the generation, so it answers "is
        // this still the backdrop anyone asked for" without depending on when
        // the host learned the Sequence's id (see the USDZ branch).
        let generation = backdropUSDZGeneration
        Task { @MainActor in
            do {
                let texture = try await TextureResource(contentsOf: url, options: .init(semantic: .color))
                guard self.backdropUSDZGeneration == generation else { return }
                let mesh: MeshResource
                switch field {
                case .equirect360:
                    // Deliberately still `generateSphere`: RealityKit's own
                    // UV convention renders 360° correctly, and swapping the
                    // generator risks a silent handedness regression (the
                    // same reasoning as the Mac's `BackdropMesh`).
                    mesh = MeshResource.generateSphere(radius: radius)
                case .equirect180, .appleImmersive, .custom:
                    // PARTIAL SHELL from the authored coverage: the shell
                    // sweeps exactly `field.horizontalDegrees`, centered on
                    // forward, so a 180° plate stops at the hemisphere
                    // boundary and a 190°/220° plate sweeps its real field
                    // instead of being smeared across a full sphere
                    // (ShellGeometry — the runtime twin of the Mac's
                    // `MaestroKit.BackdropGeometry`, conventions kept
                    // in sync by contract).
                    //
                    // NOTE: Apple Immersive remains an EDITOR APPROXIMATION
                    // here — Apple's projection is parametric fisheye, not
                    // equirectangular, so the equirect mapping onto the
                    // correct angular span is coverage-true but not
                    // lens-true. Real AIV playback goes through
                    // VideoPlayerComponent, never this path.
                    let shellData = ShellGeometry.shell(field: field, radius: radius)
                    var descriptor = MeshDescriptor(name: "backdrop_\(Int(field.horizontalDegrees))")
                    descriptor.positions = MeshBuffer(shellData.positions)
                    descriptor.normals = MeshBuffer(shellData.normals)
                    descriptor.textureCoordinates = MeshBuffer(shellData.uvs)
                    descriptor.primitives = .triangles(shellData.indices)
                    if let generated = try? MeshResource.generate(from: [descriptor]) {
                        mesh = generated
                    } else {
                        logger.warning("Partial shell generation failed for \(field.horizontalDegrees)°; falling back to a full sphere.")
                        mesh = MeshResource.generateSphere(radius: radius)
                    }
                }
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                let model = ModelComponent(mesh: mesh, materials: [material])
                skybox.components.set(model)
                // Inside-out so the user sees the texture from inside.
                skybox.scale = SIMD3<Float>(-1, 1, 1)
                skybox.isEnabled = true
                self.currentImageSkyboxActive = true
                // The cue's placement, on top of the mirror just written.
                self.applyBackdropPlacement()
            } catch {
                logger.warning("Failed to load backdrop image '\(file)': \(String(describing: error))")
            }
        }
    }

    /// Reverse `bindImageSkybox` — drop the ModelComponent so the
    /// skybox entity returns to its empty-anchor state for the next
    /// sequence's binding. Idempotent (no-op when no image was bound).
    private func tearDownImageSkybox() {
        guard currentImageSkyboxActive,
              let skybox = videoManager.videoEntityRegistry["skybox"]
        else { return }
        skybox.components.remove(ModelComponent.self)
        skybox.scale = .one
        skybox.isEnabled = false
        currentImageSkyboxActive = false
    }

    /// Resolve an asset id to a file URL. Consults the loaded
    /// experience's media resolver first (so live / packaged
    /// experiences shadow the app bundle), then falls back to the main
    /// bundle. `open` so live editors with a local-first resolver
    /// (MaestroVision — in-session imports exist only in its device
    /// cache, invisible to the frozen load-time resolver) can route
    /// backdrop lookups the same way as every other asset path.
    open func resolveBackdropAssetURL(file: String, kind: MediaKind) -> URL? {
        if let resolved = loadedExperience?.mediaResolver.url(for: file, kind: kind) {
            return resolved
        }
        let stem = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: stem.isEmpty ? file : stem, withExtension: ext.isEmpty ? "usdz" : ext)
    }

    /// Open or dismiss the ImmersiveSpace to match the sequence's
    /// `presentation`. Updates `immersionStyle` so the active style
    /// (full vs mixed) tracks the sequence even when the space is
    /// already open. Toggles the always-loaded ambient background
    /// entities so they don't occlude passthrough in mixed-mode
    /// sequences.
    public func applySequencePresentation(_ sequence: SequenceDefinition) async {
        logger.info("[presentation] applySequencePresentation sequence=\(sequence.id) presentation=\(String(describing: sequence.presentation)) spaceState=\(String(describing: self.immersiveSpaceState))")
        switch sequence.presentation {
        case .immersive, .mixed:
            let desiredStyle: ImmersionStyle = sequence.presentation == .immersive ? .full : .mixed
            applyAmbientBackgroundVisibility(for: sequence)
            if immersiveSpaceState == .open {
                immersionStyle = desiredStyle
                return
            }
            guard let openSpace else { return }
            immersionStyle = desiredStyle
            immersiveSpaceState = .inTransition
            switch await openSpace(immersiveSpaceID) {
            case .opened:
                immersiveSpaceState = .open
            case .userCancelled, .error:
                immersiveSpaceState = .closed
            @unknown default:
                immersiveSpaceState = .closed
            }
        case .windowed:
            guard immersiveSpaceState != .closed, let dismissSpace else { return }
            immersiveSpaceState = .inTransition
            await dismissSpace()
            immersiveSpaceState = .closed
        }
    }

    /// Show or hide the always-loaded ambient background entities
    /// based on the sequence's presentation + backdrop. The
    /// `ambientBackdropName` set at init controls which scene-tree
    /// entity (e.g. a Reality Composer Pro anchor) is toggled
    /// alongside the skybox.
    private func applyAmbientBackgroundVisibility(for sequence: SequenceDefinition) {
        let rcpBackdrop: Entity? = {
            guard let name = ambientBackdropName else { return nil }
            return immersiveSceneRoot?.findEntity(named: name)
        }()
        let skybox = immersiveSceneRoot?.findEntity(named: "skybox")
            ?? videoManager.videoEntityRegistry["skybox"]
        switch sequence.presentation {
        case .immersive:
            switch sequence.immersiveBackdrop {
            case .none:
                rcpBackdrop?.isEnabled = true
                skybox?.isEnabled = false
            case .video?, .image?:
                rcpBackdrop?.isEnabled = false
                skybox?.isEnabled = true
            case .usdz?:
                rcpBackdrop?.isEnabled = false
                skybox?.isEnabled = false
            }
        case .mixed:
            rcpBackdrop?.isEnabled = false
            skybox?.isEnabled = false
        case .windowed:
            break
        }
    }

    public func stopSequence(fullReset: Bool = false) {
        // A host's Stop is the person's request too (OD-111): an engine Go To
        // or ending still in flight must not start a Sequence after it.
        cancelEngineNavigationForHost()
        sequenceEngine.stop(resetEntities: true, fullReset: fullReset)
        // The backdrop video channel is PROTECTED from stopAll() so its
        // VideoPlayerComponent survives sequence-to-sequence rebinds
        // (re-attaching the component after a strip is flaky on device).
        // Protection must not mean the transport can't silence it: PAUSE
        // the player — picture freezes, audio stops, the component stays
        // attached, and the replay fast path resumes it on the next play.
        videoManager.player(for: Self.backdropVideoChannel)?.pause()
        activeSequenceId = nil
        // Stopped: no ending is still deciding (OD-42).
        heldStoryDecision = nil
        // Stopped: the options and any comfort pause go with the story.
        endChoiceWait()
        if isStoryPausedForComfort {
            isStoryPausedForComfort = false
            comfortNotice.show(comfortSignals.activeWarning)
        }
    }

    /// Look up `id` in the currently-loaded ChapterScript document,
    /// converting the matching DTO into a runtime `SequenceDefinition`.
    /// Returns nil if no document is loaded or the id isn't present.
    /// `open` so live editors whose working document diverges from the
    /// load-time snapshot (MaestroVision) can resolve auto-advance
    /// targets against their CURRENT document instead.
    open func sequenceFromLoadedDocument(id: String) -> SequenceDefinition? {
        guard let dto = loadedExperience?.document.sequences.first(where: { $0.id == id }) else { return nil }
        return runtimeSequence(dto)
    }

    /// All runtime sequences that the player UI should render in any
    /// timeline scrub bar. When a ChapterScript document is loaded
    /// (live, file-open, or local folder), returns its sequences mapped
    /// through the same conversion as loaded Sequence lookup. Empty when nothing is loaded
    /// — the consumer's UI surfaces an empty state.
    public var displaySequences: [SequenceDefinition] {
        guard let document = loadedExperience?.document else { return [] }
        return document.sequences.compactMap { runtimeSequence($0) }
    }

    /// Unknown actions are represented by the bridge, so they cannot erase a
    /// valid Sequence here. A conversion safety refusal is different and must
    /// be reported rather than hidden behind `try?`.
    private func runtimeSequence(_ dto: SequenceDefinitionDTO) -> SequenceDefinition? {
        do {
            return try SequenceDefinition(dto: dto)
        } catch {
            logger.error("Sequence '\(dto.id, privacy: .public)' could not be converted: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Phase transitions

    /// Minimal phase router. `"immersive"` opens the ImmersiveSpace and
    /// auto-plays the default sequence. `"idle"` stops playback and
    /// dismisses the space.
    public func transitionToPhase(_ phase: String) async {
        switch phase {
        case "immersive":
            guard immersiveSpaceState == .closed else {
                logger.info("transitionToPhase(immersive) skipped — state=\(String(describing: self.immersiveSpaceState))")
                return
            }
            guard let openSpace else {
                logger.error("transitionToPhase(immersive): openSpace closure not injected")
                return
            }
            immersiveSpaceState = .inTransition
            let result = await openSpace(immersiveSpaceID)
            switch result {
            case .opened:
                immersiveSpaceState = .open
                logger.info("Immersive space opened")
            case .userCancelled, .error:
                immersiveSpaceState = .closed
                logger.warning("Immersive space open failed: \(String(describing: result))")
            @unknown default:
                immersiveSpaceState = .closed
            }

        case "idle":
            stopSequence(fullReset: true)
            if let dismissSpace, immersiveSpaceState != .closed {
                immersiveSpaceState = .inTransition
                await dismissSpace()
                immersiveSpaceState = .closed
                logger.info("Immersive space dismissed")
            }

        default:
            logger.warning("Unknown phase: \(phase)")
        }
    }
}
