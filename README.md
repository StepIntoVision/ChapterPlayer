# ChapterPlayer

The open source visionOS runtime that plays [ChapterScript](https://github.com/StepIntoVision/ChapterScript) documents. It bundles the sequence engine, spatial audio and video managers, entity factory, gate detection, and live-development client into a single Swift package, so a consuming app only needs to ship its UI, content, and product-specific extensions.

ChapterPlayer is the same runtime that powers headset playback in [Maestro](https://maestrostud.io), the commercial authoring suite: MaestroVision embeds it unchanged. Maestro's Mac editor previews with its own evaluator, not with ChapterPlayer. Website: [chapterscript.com](https://chapterscript.com).

It reads ChapterScript **format 8**. Documents saved in formats 2–7 are migrated on load (`Migrator.migrate`; format 8 moves each Object's Interactions into the Sequences that use it); a document newer than the linked ChapterScript fails to load with `sourceVersionTooNew`. Over a Maestro live link the format is stated, not gated: a newer Mac document is decoded as it stands and the host is told the two versions differ.

## What's in the package

- **`SequenceEngine`** — the declarative sequence/segment choreographer. Always resets entities on sequence change; pluggable executor protocols for entity / audio / video / attachment / effect actions.
- **`GateDetectionController`** — holds playback at a segment boundary until the gate resolves, behind the `GateDetecting` protocol. Gate kinds are ChapterScript's `GateType`: tap, an orchestrator message, either of those, viewer facing, proximity, grab, or a story-state condition; a gate can also time out.
- **`SpatialAudioManager`** — `AVAudioEngine`-based channel system with audio buses, ducking rules, audio zones, and loop configs.
- **`VideoPlaybackManager`** — per-channel `AVPlayer` orchestrator: flat scene panels, attachment-based SwiftUI overlays, and 360°/180° immersive skybox playback via `VideoPlayerComponent`.
- **`EntityFactory`** + **`DocumentEntityLoader`** — build RealityKit entities for ChapterScript `EntityDefinition`s (primitives, USDZs, text, lights, video panels) and materialize a document's entities into the immersive scene, registered with the executors.
- **`BackdropCueDriver`** — drives sequence backdrop presentation behind the `BackdropCuePresenting` protocol.
- **`MotionCurveEvaluator`** — a thin delegate over ChapterScript's canonical `MotionCurveSampling`, so playback matches editors' scrub previews, motion trails, and graph rendering exactly.
- **Experience providers + media resolvers** — `BundledExperienceProvider` / `LocalFolderExperienceProvider` for shipped content, and `LiveDevExperienceProvider` + `LiveServerBrowser` + `LiveMediaResolver` for Bonjour discovery and concurrent asset prefetch from a Maestro Studio peer on the LAN. `AssetPreloader` warms media before playback.
- **`PulseRingEntity` / `SparkBurstEntity`** — procedural VFX primitives the engine fires via the corresponding segment actions.

## Not played yet

Format fields the runtime reads only partly today (checked 2026-11-14):

- `VideoActionDTO.convergence` and `SequenceStereoAutomation` (`SequenceDefinitionDTO.stereoTracks`): the bridge `VideoAction.init(_ dto: VideoActionDTO)` (`ChapterEngine/ChapterScript+Runtime.swift`) does not copy them; `VideoPlaybackManager` reads them from the document through `authoredStereoProvider` and works out the effective convergence, but does not draw it, because a `VideoMaterial` panel shows one texture to both eyes. A frame-packed panel is not split by eye.
- `VideoActionDTO.virtualCamera` (Flat View) is drawn on Screens by remapping the panel's texture coordinates (`HeadsetStereoPresentation`), with known differences from the Mac's kernel: an edge stretch outside a half-sphere's coverage, square corners, and grading before the flatten.
- A Cue's `choice` is read from the document (`authoredGate(for:)`), not carried on the runtime `SegmentGate`.

## Consumer responsibilities

- Provide the visionOS scenes (`@main`, `WindowGroup`, `ImmersiveSpace`) and inject `openImmersiveSpace` / `dismissImmersiveSpace`.
- Register custom action handlers via the `EffectActionExecutor`'s custom-action escape hatch.
- Register product-specific entity factories (USDZs, audio-reactive elements, etc.) on top of the built-in registry.
- Provide a `MediaResolver` for bundled assets (or use `BundleMediaResolver`).

## Installing

`Package.swift`:

```swift
.package(url: "https://github.com/StepIntoVision/ChapterPlayer.git", branch: "main")
```

ChapterPlayer tracks the ChapterScript format package at `main` while the wire format is pre-1.0; both will pin to tagged versions once the format settles. A local sibling checkout of `ChapterScript` overrides the remote by package identity (the standard local-override workflow).

## Requirements

- visionOS 26+ (visionOS only: there is no macOS build and no test target; Maestro covers it with a generic visionOS build and host tests)
- Swift 6.2 / Xcode 26+
- [ChapterScript](https://github.com/StepIntoVision/ChapterScript) (resolved automatically)

## Credits

MIT means a visible credit is never required beyond the license notice itself.
That said, if your app ships with ChapterPlayer inside, a mention is
appreciated, and we'd genuinely love to hear what you made:
[maestro@stepinto.vision](mailto:maestro@stepinto.vision).

## License

MIT — see `LICENSE`.
