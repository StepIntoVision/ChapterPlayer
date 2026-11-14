//
//  HeadsetStereoPresentation.swift
//  ChapterPlayer
//
//  CONVERGENCE AND FLAT VIEW ON THE HEADSET, BY THE MAC'S RULES (OD-24).
//
//  The Mac previews two per-occurrence stereo decisions:
//
//    CONVERGENCE  the occurrence's base plus its Screen's automation ride,
//                 summed and clamped by `SequenceStereoAutomation`. That rule
//                 lives in ChapterScript, so the headset calls the SAME
//                 function rather than a copy of it.
//
//    FLAT VIEW    a virtual camera (`VirtualCameraSpec`) that cuts a
//                 rectilinear window out of a projected master. Its keys are
//                 fractions of the occurrence's span, resolved by MaestroKit's
//                 `VirtualCameraGraphAdapter.resolved`, and its pixels come
//                 from the Mac's `flattenEquirect` kernel. ChapterPlayer
//                 depends on ChapterScript alone, so both are MIRRORED here,
//                 line for line, and `RuntimeRealizationTests` holds the two
//                 to the same answers. Change one, change both.
//
//  HOW THE HEADSET DRAWS A FLAT VIEW. `VideoMaterial` owns a panel's pixels
//  and has no per-pixel hook, so the kernel's mapping is applied to GEOMETRY
//  instead: the panel becomes a grid whose every vertex carries the texture
//  coordinate the kernel would sample for that point of the window. Between
//  vertices the GPU interpolates linearly, which is the only approximation;
//  at 32 by 24 cells it is far below a pixel of a panel at reading distance.
//
//  THE PER-EYE PANEL SURFACE (OD-24). Convergence moves one eye's picture
//  against the other's, and a frame-packed master holds two pictures in one
//  raster; a `VideoMaterial` plane shows one texture to both eyes, so neither
//  can be drawn through it. `StereoPanelMaterial` (the `StereoPanel.usda`
//  ShaderGraph resource, which switches on the camera index) samples each
//  eye's own rectangle of the decoded frame. WHICH rectangle is decided
//  here, by the Mac's rule (`SourceMediaInterpretation.region(for:)`, mirrored
//  line for line and held to it by `RuntimeRealizationTests`): the packing
//  and eye order pick the half, and the effective disparity (the file's own
//  adjustment plus the occurrence's Convergence) shifts each eye by half of
//  it, in opposite directions, in units of that eye's width.
//
//  A Flat View on a per-eye surface is built with eye-local texture
//  coordinates (`region: .whole`) and the surface maps them into each eye's
//  rectangle, so the panel is cut from both eyes rather than from the left
//  one alone.
//
//  NOT YET BOUND. `VideoPlaybackManager` still draws every panel through
//  `VideoMaterial` (a Flat View from the left eye) and logs an authored
//  Convergence as not rendered. Binding `StereoPanelMaterial` to a panel's
//  decoded frames, when `needsPerEyeSurface` says so, is the remaining work
//  of TODO-66, and only a worn Vision Pro can say the result is right.
//
//  Pure: no RealityKit, no AVFoundation, so every rule is testable without a
//  scene. The one exception is the Flat View rebuild meter, which logs.
//

import Foundation
import simd
import os
import ChapterScript

public enum HeadsetStereoPresentation {

    // MARK: - What the document says

    /// The authored facts the headset needs, handed over by the host that
    /// holds the document (`VideoPlaybackManager.authoredStereoProvider`).
    public struct Authored: Sendable {
        public var sequence: SequenceDefinitionDTO
        /// The document's per-file video decisions, keyed by file name.
        public var videoInterpretations: [String: VideoInterpretation]

        public init(sequence: SequenceDefinitionDTO,
                    videoInterpretations: [String: VideoInterpretation] = [:]) {
            self.sequence = sequence
            self.videoInterpretations = videoInterpretations
        }
    }

    /// One authored `playVideo` occurrence's stereo decisions.
    public struct Occurrence: Equatable, Sendable {
        /// The authored action's id (`VideoAction.occurrenceId`).
        public var id: String
        public var file: String
        /// `MediaDestination.key` of the Screen it plays on: what a
        /// convergence ride is keyed by.
        public var destinationKey: String
        /// The occurrence's own convergence; nil and 0 both mean the
        /// source's own stereo relationship.
        public var baseConvergence: Float
        public var virtualCamera: VirtualCameraSpec?
        /// How the clip says its file packs its eyes.
        public var clipLayout: ChapterScript.VideoLayout
        /// The author's decisions about the file, when there are any.
        public var decidedLayout: ChapterScript.VideoLayout?
        public var decidedProjection: SourceProjection?
        public var eyeOrder: StereoEyeOrder
        /// The Screen's convergence ride: only this destination's track, so
        /// a per-tick read does not search the whole Sequence.
        public var stereoTracks: [StereoAutomationTrack]

        public init(id: String, file: String, destinationKey: String,
                    baseConvergence: Float, virtualCamera: VirtualCameraSpec?,
                    clipLayout: ChapterScript.VideoLayout,
                    decidedLayout: ChapterScript.VideoLayout?,
                    decidedProjection: SourceProjection?,
                    eyeOrder: StereoEyeOrder,
                    stereoTracks: [StereoAutomationTrack]) {
            self.id = id
            self.file = file
            self.destinationKey = destinationKey
            self.baseConvergence = baseConvergence
            self.virtualCamera = virtualCamera
            self.clipLayout = clipLayout
            self.decidedLayout = decidedLayout
            self.decidedProjection = decidedProjection
            self.eyeOrder = eyeOrder
            self.stereoTracks = stereoTracks
        }

        /// True when the clip carries anything this file resolves.
        public var hasStereoDecision: Bool {
            virtualCamera != nil || baseConvergence != 0 || !stereoTracks.isEmpty
        }
    }

    /// The authored occurrence with this id, or nil when the id names no
    /// `playVideo` in the Sequence.
    public static func occurrence(id: String, in authored: Authored) -> Occurrence? {
        for segment in authored.sequence.segments {
            for entry in segment.authoredActions where entry.id == id {
                guard case .playVideo(let video) = entry.action else { return nil }
                let key = destinationKey(of: video.presentation)
                let decided = authored.videoInterpretations[video.file]
                return Occurrence(
                    id: id, file: video.file, destinationKey: key,
                    baseConvergence: video.convergence ?? 0,
                    virtualCamera: video.virtualCamera,
                    clipLayout: video.layout,
                    decidedLayout: decided?.layout,
                    decidedProjection: decided?.projection,
                    eyeOrder: decided?.eyeOrder ?? .leftFirst,
                    stereoTracks: authored.sequence.stereoTracks.filter { $0.destination == key })
            }
        }
        return nil
    }

    /// `MediaDestination.key`, mirrored from MaestroKit: an entity's own
    /// name, and namespaced keys for the environment and attachments so an
    /// entity called "immersive" cannot collide with them.
    public static func destinationKey(of presentation: ChapterScript.VideoPresentation) -> String {
        switch presentation {
        case .entity(let name, _, _): return name
        case .immersive:              return "\u{1}immersive"
        case .attachment(let id):     return "\u{1}attachment/\(id)"
        }
    }

    // MARK: - The clock

    /// Where `time` sits in the occurrence, 0...1 — the Kit's
    /// `(time - start) / max(end - start, 1e-9)`, with the engine's stamp
    /// (`firedAt`, `timelineSpan`) as start and length. An unstamped play
    /// has no place on the clock and reads as its first frame.
    public static func fraction(at time: TimeInterval?, firedAt: TimeInterval?,
                                span: TimeInterval?) -> Double {
        guard let time, let firedAt, let span else { return 0 }
        return (time - firedAt) / max(span, 1e-9)
    }

    // MARK: - Convergence

    /// The effective convergence at Sequence time `time`: THE one rule,
    /// ChapterScript's, so the Mac and the headset cannot disagree.
    public static func effectiveConvergence(of occurrence: Occurrence,
                                            at time: TimeInterval) -> Float {
        SequenceStereoAutomation.effectiveConvergence(
            base: occurrence.baseConvergence, destination: occurrence.destinationKey,
            at: time, in: occurrence.stereoTracks)
    }

    // MARK: - Flat View: the aim

    /// THE AIM AT ONE INSTANT. Mirrors `VirtualCameraGraphAdapter.resolved`
    /// exactly: a keyed channel is sampled, an unkeyed one keeps its scalar,
    /// the field of view is clamped to the format's window, and the keys are
    /// spent so nothing downstream resolves them again.
    public static func resolvedAim(_ spec: VirtualCameraSpec,
                                   atFraction fraction: Double) -> VirtualCameraSpec {
        guard let keys = spec.keys, !keys.isEmpty else { return spec }
        let t = min(max(fraction, 0), 1)
        var out = spec
        if let curve = keys.yaw, !curve.keys.isEmpty {
            out.yaw = SequenceAnimationEvaluator.evaluate(curve, at: t, rest: spec.yaw)
        }
        if let curve = keys.pitch, !curve.keys.isEmpty {
            out.pitch = SequenceAnimationEvaluator.evaluate(curve, at: t, rest: spec.pitch)
        }
        if let curve = keys.roll, !curve.keys.isEmpty {
            out.roll = SequenceAnimationEvaluator.evaluate(curve, at: t, rest: spec.roll)
        }
        if let curve = keys.fov, !curve.keys.isEmpty {
            let sampled = SequenceAnimationEvaluator.evaluate(curve, at: t, rest: spec.fovDegrees)
            out.fovDegrees = min(max(sampled, VirtualCameraSpec.fovRange.lowerBound),
                                 VirtualCameraSpec.fovRange.upperBound)
        }
        out.keys = nil
        return out
    }

    /// Whether the aim moves over the occurrence, so the panel needs the
    /// per-frame tick.
    public static func isKeyed(_ spec: VirtualCameraSpec?) -> Bool {
        guard let keys = spec?.keys else { return false }
        return !keys.isEmpty
    }

    // MARK: - Flat View: what the master covers

    /// The projection a container's `ProjectionKind` extension states, in the
    /// shared vocabulary. Mirrors the Mac's `ProbedProjection`: an unknown
    /// value is silence, never a guess.
    public static func declaredProjection(kind: String?) -> SourceProjection? {
        switch kind {
        case "Rectilinear":                                return .rectilinear
        case "HalfEquirectangular":                        return .halfEquirectangular
        case "Equirectangular":                            return .equirectangular
        case "AppleImmersiveVideo", "ParametricImmersive": return .appleImmersive
        default:                                           return nil
        }
    }

    /// THE CONTAINER FIRST, THE AUTHOR SECOND, RECTILINEAR LAST — the Mac's
    /// `SourceMediaInterpretation.resolve` precedence for projection.
    public static func resolvedProjection(declaredKind: String?,
                                          decided: SourceProjection?) -> SourceProjection {
        declaredProjection(kind: declaredKind) ?? decided ?? .rectilinear
    }

    /// The angles a master covers. Mirrors `VirtualCameraFlattener.Coverage`:
    /// Apple Immersive reads as a half sphere, and a rectilinear source (the
    /// authoring boundary refuses a Flat View on one) reads as a full one.
    public struct Coverage: Equatable, Sendable {
        public var horizontalSpanRadians: Float
        public var verticalSpanRadians: Float

        public init(horizontalSpanRadians: Float, verticalSpanRadians: Float) {
            self.horizontalSpanRadians = horizontalSpanRadians
            self.verticalSpanRadians = verticalSpanRadians
        }

        public static let equirect360 = Coverage(horizontalSpanRadians: 2 * .pi,
                                                 verticalSpanRadians: .pi)
        public static let equirect180 = Coverage(horizontalSpanRadians: .pi,
                                                 verticalSpanRadians: .pi)

        public static func forProjection(_ projection: SourceProjection) -> Coverage {
            switch projection {
            case .equirectangular: return .equirect360
            case .halfEquirectangular, .appleImmersive: return .equirect180
            case .rectilinear: return .equirect360
            }
        }

        /// A whole sphere around: the window can cross the seam behind.
        public var wrapsAround: Bool { horizontalSpanRadians >= 2 * .pi - 1e-4 }
    }

    /// Which part of the decoded frame holds the eye a Flat View is cut
    /// from, in texture space (origin top-left, 0...1).
    ///
    /// The master render flattens each eye from its own region; a panel shows
    /// one picture, so the headset cuts the LEFT eye, the Mac's first eye. A
    /// multiview or mono file decodes one whole picture.
    public struct EyeRegion: Equatable, Sendable {
        public var x: Float, y: Float, width: Float, height: Float

        public init(x: Float, y: Float, width: Float, height: Float) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public static let whole = EyeRegion(x: 0, y: 0, width: 1, height: 1)
    }

    /// The author's packing decision outranks the clip's record, as on the
    /// Mac; the eye order picks which half is the left eye.
    public static func leftEyeRegion(clipLayout: ChapterScript.VideoLayout,
                                     decidedLayout: ChapterScript.VideoLayout?,
                                     eyeOrder: StereoEyeOrder) -> EyeRegion {
        eyeRegion(.left, clipLayout: clipLayout, decidedLayout: decidedLayout,
                  eyeOrder: eyeOrder, effectiveDisparity: 0)
    }

    // MARK: - Per eye (Convergence and frame packing)

    /// One of the viewer's eyes, as the per-eye surface's camera index names
    /// them.
    public enum Eye: String, Sendable, CaseIterable {
        case left, right
    }

    /// The total horizontal shift between the eyes, as a fraction of an
    /// eye's width: the file's OWN disparity adjustment plus the author's
    /// Convergence. The Mac's `SourceMediaInterpretation.effectiveDisparity`.
    public static func effectiveDisparity(convergence: Float,
                                          sourceDisparityAdjustment: Float = 0) -> Float {
        sourceDisparityAdjustment + convergence
    }

    /// One eye's sampling shift, in units of that eye's own width. SPLIT
    /// EVENLY, in opposite directions, so the panel's border does not move as
    /// the author rides Convergence: pushing the scene farther moves the left
    /// picture right (sampled from farther left) and the right picture left.
    /// Mirrors `SourceMediaInterpretation.disparityShift(for:)`.
    public static func disparityShift(_ eye: Eye, effectiveDisparity total: Float) -> Float {
        guard total != 0 else { return 0 }
        switch eye {
        case .left:  return -total / 2
        case .right: return  total / 2
        }
    }

    /// WHERE ONE EYE'S PICTURE IS in the decoded frame (texture space, origin
    /// top-left), Convergence included. Mirrors
    /// `SourceMediaInterpretation.region(for:)`: the author's packing decision
    /// outranks the clip's record, the eye order picks which half is which,
    /// a mono or multiview frame is whole for each eye, and the shift may
    /// carry the rectangle past the frame's edge (the surface samples black
    /// there, as the Mac's crop does).
    public static func eyeRegion(_ eye: Eye, clipLayout: ChapterScript.VideoLayout,
                                 decidedLayout: ChapterScript.VideoLayout?,
                                 eyeOrder: StereoEyeOrder,
                                 effectiveDisparity: Float) -> EyeRegion {
        let second: Eye = eyeOrder == .leftFirst ? .right : .left
        let takesSecondHalf = eye == second
        var region: EyeRegion
        switch decidedLayout ?? clipLayout {
        case .sideBySide:
            region = EyeRegion(x: takesSecondHalf ? 0.5 : 0, y: 0, width: 0.5, height: 1)
        case .overUnder:
            region = EyeRegion(x: 0, y: takesSecondHalf ? 0.5 : 0, width: 1, height: 0.5)
        case .mono, .multiviewHEVC:
            region = .whole
        }
        region.x += disparityShift(eye, effectiveDisparity: effectiveDisparity) * region.width
        return region
    }

    /// How one eye samples: eye-local RealityKit texture coordinates (origin
    /// BOTTOM-left, 0...1 over the panel) to frame coordinates, as
    /// `uv * scale + offset`. The parameters the per-eye surface is handed.
    public struct EyeSampling: Equatable, Sendable {
        public var scale: SIMD2<Float>
        public var offset: SIMD2<Float>

        public init(scale: SIMD2<Float>, offset: SIMD2<Float>) {
            self.scale = scale
            self.offset = offset
        }

        public static let identity = EyeSampling(scale: SIMD2(1, 1), offset: .zero)

        /// Where an eye-local coordinate samples the frame.
        public func frameCoordinate(_ uv: SIMD2<Float>) -> SIMD2<Float> { uv * scale + offset }
    }

    /// A top-left region as a bottom-left sampling: u maps straight across;
    /// v runs up, so the region's BOTTOM edge (`1 - y - height`) is where an
    /// eye-local v of 0 lands.
    public static func sampling(for region: EyeRegion) -> EyeSampling {
        EyeSampling(scale: SIMD2(region.width, region.height),
                    offset: SIMD2(region.x, 1 - region.y - region.height))
    }

    /// Everything the per-eye surface needs for one occurrence at one
    /// instant.
    public struct PanelEyeMapping: Equatable, Sendable {
        public var left: EyeSampling
        public var right: EyeSampling
        /// True for a multiview file, whose eyes decode as TWO pictures: the
        /// surface binds each eye's own. Otherwise both eyes sample one
        /// decoded frame (frame-packed halves, or one mono picture).
        public var picturesPerEye: Bool

        public init(left: EyeSampling, right: EyeSampling, picturesPerEye: Bool) {
            self.left = left
            self.right = right
            self.picturesPerEye = picturesPerEye
        }

        /// Both eyes see the same pixels: nothing per-eye to draw.
        public var isMonoscopic: Bool { left == right && !picturesPerEye }
    }

    /// The per-eye mapping of a packing and an effective disparity.
    public static func panelEyeMapping(clipLayout: ChapterScript.VideoLayout,
                                       decidedLayout: ChapterScript.VideoLayout?,
                                       eyeOrder: StereoEyeOrder,
                                       effectiveDisparity: Float) -> PanelEyeMapping {
        func eye(_ e: Eye) -> EyeSampling {
            sampling(for: eyeRegion(e, clipLayout: clipLayout, decidedLayout: decidedLayout,
                                    eyeOrder: eyeOrder, effectiveDisparity: effectiveDisparity))
        }
        return PanelEyeMapping(left: eye(.left), right: eye(.right),
                               picturesPerEye: (decidedLayout ?? clipLayout) == .multiviewHEVC)
    }

    /// The occurrence's mapping at Sequence time `time`: its packing, and its
    /// effective Convergence by THE one rule (`effectiveConvergence`) on top
    /// of the file's own adjustment.
    public static func panelEyeMapping(of occurrence: Occurrence, at time: TimeInterval,
                                       sourceDisparityAdjustment: Float = 0) -> PanelEyeMapping {
        panelEyeMapping(
            clipLayout: occurrence.clipLayout, decidedLayout: occurrence.decidedLayout,
            eyeOrder: occurrence.eyeOrder,
            effectiveDisparity: effectiveDisparity(
                convergence: effectiveConvergence(of: occurrence, at: time),
                sourceDisparityAdjustment: sourceDisparityAdjustment))
    }

    /// Whether an occurrence needs the per-eye surface at all: a FRAME-PACKED
    /// file (two pictures in one raster, which `VideoMaterial` shows whole to
    /// both eyes), or any authored Convergence (a shift between the eyes). A
    /// multiview file's views are already routed to their eyes by
    /// `VideoMaterial`, and a mono clip has one picture, so either needs the
    /// surface only for Convergence.
    public static func needsPerEyeSurface(_ occurrence: Occurrence) -> Bool {
        let convergenceAuthored = occurrence.baseConvergence != 0
            || occurrence.stereoTracks.contains(where: \.hasAnyKeys)
        switch occurrence.decidedLayout ?? occurrence.clipLayout {
        case .sideBySide, .overUnder: return true
        case .mono, .multiviewHEVC:   return convergenceAuthored
        }
    }

    // MARK: - Flat View: the mapping

    /// The camera basis and frustum an aim implies, at one output aspect.
    /// Mirrors `VirtualCameraFlattener.params`: positive yaw looks right
    /// (+X), positive pitch looks up, roll turns the horizon about the aim,
    /// and the authored field of view is HORIZONTAL.
    public struct Basis: Equatable, Sendable {
        public var forward: SIMD3<Float>
        public var right: SIMD3<Float>
        public var up: SIMD3<Float>
        public var halfTangentX: Float
        public var halfTangentY: Float
    }

    public static func basis(aim: VirtualCameraSpec, outputAspect: Double) -> Basis {
        let yaw = aim.yaw * .pi / 180
        let pitch = aim.pitch * .pi / 180
        let roll = aim.roll * .pi / 180
        let forward = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
        let flatRight = SIMD3<Float>(cos(yaw), 0, sin(yaw))
        let flatUp = simd_normalize(simd_cross(flatRight, forward))
        let rollRotation = simd_quatf(angle: roll, axis: simd_normalize(forward))
        let right = rollRotation.act(flatRight)
        let up = rollRotation.act(flatUp)
        let clampedFOV = min(max(aim.fovDegrees, VirtualCameraSpec.fovRange.lowerBound),
                             VirtualCameraSpec.fovRange.upperBound)
        let halfTangentX = tan(clampedFOV * .pi / 360)
        let halfTangentY = halfTangentX / Float(max(outputAspect, 0.001))
        return Basis(forward: forward, right: right, up: up,
                     halfTangentX: halfTangentX, halfTangentY: halfTangentY)
    }

    /// Where a point of the window looks, on the sphere. `ndcX` runs -1 at
    /// the left edge to +1 at the right; `ndcY` runs -1 at the TOP to +1 at
    /// the bottom, because texture v runs down while the frustum's y runs up
    /// — the kernel's own convention.
    public static func sphereAngles(_ basis: Basis, ndcX: Float,
                                    ndcY: Float) -> (longitude: Float, latitude: Float) {
        let d = simd_normalize(basis.forward
                               + basis.right * (ndcX * basis.halfTangentX)
                               - basis.up * (ndcY * basis.halfTangentY))
        return (atan2(d.x, -d.z), asin(min(max(d.y, -1), 1)))
    }

    /// THE MAC KERNEL'S SAMPLE POINT for one point of the window, in texture
    /// space of the eye's picture (origin top-left). Nil outside the
    /// master's coverage, where the Mac paints black.
    public static func textureCoordinate(aim: VirtualCameraSpec, coverage: Coverage,
                                         outputAspect: Double,
                                         ndcX: Float, ndcY: Float) -> SIMD2<Float>? {
        let b = basis(aim: aim, outputAspect: outputAspect)
        let (longitude, latitude) = sphereAngles(b, ndcX: ndcX, ndcY: ndcY)
        if abs(longitude) > coverage.horizontalSpanRadians * 0.5
            || abs(latitude) > coverage.verticalSpanRadians * 0.5 { return nil }
        return SIMD2(longitude / coverage.horizontalSpanRadians + 0.5,
                     0.5 - latitude / coverage.verticalSpanRadians)
    }

    /// A Flat View panel: positions in the panel's own plane (centered,
    /// +Y up, facing +Z) and RealityKit texture coordinates (origin
    /// bottom-left), four vertices and two triangles per cell.
    public struct FlatViewGrid: Equatable, Sendable {
        public var positions: [SIMD3<Float>]
        public var uvs: [SIMD2<Float>]
        public var indices: [UInt32]
        public var columns: Int
        public var rows: Int
    }

    /// The panel grid whose texture coordinates ARE the kernel's mapping.
    ///
    /// Two places the geometry has to differ from the kernel, both stated:
    ///
    ///   OUTSIDE THE COVERAGE of a half-sphere master the Mac paints black;
    ///   a vertex there is held on the coverage's edge, so the edge pixel
    ///   stretches instead. A worn check decides whether that is acceptable.
    ///
    ///   ACROSS THE SEAM behind a 360 master the longitude jumps from +180 to
    ///   -180 degrees. Longitudes are unwrapped around the aim so the grid
    ///   stays continuous, then each cell is shifted back by whole turns so
    ///   its middle lies in 0...1 (cells own their vertices for exactly
    ///   this), so only a column of cells that straddles the seam samples
    ///   past the edge, and only by part of one cell.
    ///
    /// MEASURED. Every build is timed into `meter` (the shared
    /// `flatViewRebuildMeter` by default), which logs the rebuild cost at
    /// debug level once a second's worth of rebuilds (30, one per 33 ms tick
    /// while a keyed aim moves) has accumulated. Pass nil to build unmeasured.
    public static func flatViewGrid(aim: VirtualCameraSpec, coverage: Coverage,
                                    region: EyeRegion = .whole,
                                    width: Float, height: Float,
                                    columns: Int = 32, rows: Int = 24,
                                    meter: FlatViewRebuildMeter? = HeadsetStereoPresentation.flatViewRebuildMeter) -> FlatViewGrid {
        let started = ContinuousClock.now
        let grid = unmeteredFlatViewGrid(aim: aim, coverage: coverage, region: region,
                                         width: width, height: height,
                                         columns: columns, rows: rows)
        meter?.record(ContinuousClock.now - started)
        return grid
    }

    private static func unmeteredFlatViewGrid(aim: VirtualCameraSpec, coverage: Coverage,
                                              region: EyeRegion,
                                              width: Float, height: Float,
                                              columns: Int, rows: Int) -> FlatViewGrid {
        let cols = max(1, columns), rowCount = max(1, rows)
        let b = basis(aim: aim, outputAspect: Double(width / max(height, 0.0001)))
        let halfSpan = coverage.horizontalSpanRadians * 0.5
        let halfVertical = coverage.verticalSpanRadians * 0.5
        let centerLongitude = atan2(b.forward.x, -b.forward.z)

        // Texture-space (u, v) of every grid corner, row-major from the top.
        var corners: [SIMD2<Float>] = []
        corners.reserveCapacity((cols + 1) * (rowCount + 1))
        for j in 0...rowCount {
            let ndcY = Float(j) / Float(rowCount) * 2 - 1
            for i in 0...cols {
                let ndcX = Float(i) / Float(cols) * 2 - 1
                var (longitude, latitude) = sphereAngles(b, ndcX: ndcX, ndcY: ndcY)
                if coverage.wrapsAround {
                    var delta = longitude - centerLongitude
                    while delta > .pi { delta -= 2 * .pi }
                    while delta <= -.pi { delta += 2 * .pi }
                    longitude = centerLongitude + delta
                } else {
                    longitude = min(max(longitude, -halfSpan), halfSpan)
                }
                latitude = min(max(latitude, -halfVertical), halfVertical)
                corners.append(SIMD2(longitude / coverage.horizontalSpanRadians + 0.5,
                                     0.5 - latitude / coverage.verticalSpanRadians))
            }
        }

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(cols * rowCount * 4)
        uvs.reserveCapacity(cols * rowCount * 4)
        indices.reserveCapacity(cols * rowCount * 6)
        func corner(_ i: Int, _ j: Int) -> SIMD2<Float> { corners[j * (cols + 1) + i] }
        func position(_ i: Int, _ j: Int) -> SIMD3<Float> {
            SIMD3((Float(i) / Float(cols) - 0.5) * width,
                  (0.5 - Float(j) / Float(rowCount)) * height, 0)
        }
        for j in 0..<rowCount {
            for i in 0..<cols {
                // Bottom-left, bottom-right, top-right, top-left: the winding
                // the cropped panel uses, so the grid faces the same way.
                let cell = [(i, j + 1), (i + 1, j + 1), (i + 1, j), (i, j)]
                var texture = cell.map { corner($0.0, $0.1) }
                if coverage.wrapsAround {
                    // By the cell's MIDDLE, not its smallest corner: a cell
                    // that touches the seam at one corner by a rounding
                    // error must stay where its picture is.
                    let middle = texture.reduce(0) { $0 + $1.x } / Float(texture.count)
                    let shift = middle.rounded(.down)
                    texture = texture.map { SIMD2($0.x - shift, $0.y) }
                }
                let base = UInt32(positions.count)
                for (k, (ci, cj)) in cell.enumerated() {
                    positions.append(position(ci, cj))
                    let t = texture[k]
                    uvs.append(SIMD2(region.x + t.x * region.width,
                                     1 - (region.y + t.y * region.height)))
                }
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            }
        }
        return FlatViewGrid(positions: positions, uvs: uvs, indices: indices,
                            columns: cols, rows: rowCount)
    }

    /// Whether two aims draw the same picture, so an unchanged keyed aim
    /// does not rebuild the panel every tick.
    public static func sameAim(_ a: VirtualCameraSpec?, _ b: VirtualCameraSpec?,
                               tolerance: Float = 0.01) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return abs(a.yaw - b.yaw) <= tolerance && abs(a.pitch - b.pitch) <= tolerance
                && abs(a.roll - b.roll) <= tolerance
                && abs(a.fovDegrees - b.fovDegrees) <= tolerance
        default: return false
        }
    }
}

// MARK: - Measuring the Flat View rebuild (OD-24)

/// What rebuilding Flat View grids has cost, over a window of rebuilds.
public struct FlatViewRebuildStats: Equatable, Sendable {
    public var count: Int
    public var totalSeconds: Double
    public var maxSeconds: Double

    public init(count: Int = 0, totalSeconds: Double = 0, maxSeconds: Double = 0) {
        self.count = count
        self.totalSeconds = totalSeconds
        self.maxSeconds = maxSeconds
    }

    public var meanMilliseconds: Double { count == 0 ? 0 : totalSeconds / Double(count) * 1000 }
    public var maxMilliseconds: Double { maxSeconds * 1000 }

    mutating func add(_ seconds: Double) {
        count += 1
        totalSeconds += seconds
        maxSeconds = max(maxSeconds, seconds)
    }
}

/// THE FLAT VIEW REBUILD COST, measured where it is paid. A keyed aim
/// rebuilds the panel's grid up to every 33 ms; this records each build and,
/// every `reportEvery` builds, logs the window's mean and worst at DEBUG
/// level (so it costs nothing in an ordinary log) and starts a new window.
/// The lifetime totals stay readable for a test or a diagnostics export.
///
/// Thread-safe: the grid is pure and may be built off the main actor.
public final class FlatViewRebuildMeter: Sendable {
    private struct State: Sendable {
        var window = FlatViewRebuildStats()
        var lifetime = FlatViewRebuildStats()
    }

    public let reportEvery: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ChapterPlayer", category: "Stereo")

    public init(reportEvery: Int = 30) {
        self.reportEvery = max(1, reportEvery)
    }

    /// Record one rebuild. Returns the window's stats when this rebuild
    /// closed a window (and was logged), else nil.
    @discardableResult
    public func record(_ duration: Duration) -> FlatViewRebuildStats? {
        let parts = duration.components
        return record(seconds: Double(parts.seconds) + Double(parts.attoseconds) * 1e-18)
    }

    @discardableResult
    public func record(seconds: Double) -> FlatViewRebuildStats? {
        let every = reportEvery
        let closed: FlatViewRebuildStats? = state.withLock { state in
            state.window.add(seconds)
            state.lifetime.add(seconds)
            guard state.window.count >= every else { return nil }
            let window = state.window
            state.window = FlatViewRebuildStats()
            return window
        }
        if let closed {
            let mean = closed.meanMilliseconds, worst = closed.maxMilliseconds
            Self.logger.debug("[stereo] Flat View grid rebuilt \(closed.count) times: mean \(mean, format: .fixed(precision: 3)) ms, worst \(worst, format: .fixed(precision: 3)) ms")
        }
        return closed
    }

    /// Every rebuild since the meter was made (or last reset).
    public var lifetime: FlatViewRebuildStats { state.withLock { $0.lifetime } }

    public func reset() {
        state.withLock { $0 = State() }
    }
}

public extension HeadsetStereoPresentation {
    /// The meter every Flat View build reports to unless told otherwise.
    static let flatViewRebuildMeter = FlatViewRebuildMeter()
}
