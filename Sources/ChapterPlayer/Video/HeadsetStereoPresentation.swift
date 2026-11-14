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
//  WHAT IS NOT DRAWN, AND WHY. Convergence moves one eye's picture against
//  the other's, and the headset has no per-eye surface for a panel: a
//  `VideoMaterial` plane shows one texture to both eyes. The value is
//  resolved here exactly as the Mac resolves it, so the surface that needs it
//  reads the right number on the day it exists; until then the player logs
//  that it was authored and not rendered, rather than pretending.
//
//  Pure: no RealityKit, no AVFoundation, so every rule is testable without a
//  scene.
//

import Foundation
import simd
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
        let leftFirst = eyeOrder == .leftFirst
        switch decidedLayout ?? clipLayout {
        case .sideBySide:
            return EyeRegion(x: leftFirst ? 0 : 0.5, y: 0, width: 0.5, height: 1)
        case .overUnder:
            return EyeRegion(x: 0, y: leftFirst ? 0 : 0.5, width: 1, height: 0.5)
        case .mono, .multiviewHEVC:
            return .whole
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
    public static func flatViewGrid(aim: VirtualCameraSpec, coverage: Coverage,
                                    region: EyeRegion = .whole,
                                    width: Float, height: Float,
                                    columns: Int = 32, rows: Int = 24) -> FlatViewGrid {
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
