//
//  StereoPanelMaterial.swift
//  ChapterPlayer
//
//  THE PER-EYE PANEL SURFACE (OD-24).
//
//  A `VideoMaterial` shows one texture to both eyes, so it can draw neither
//  Convergence (a shift between the eyes) nor a frame-packed master (two
//  pictures in one raster). This material can: `StereoPanel.usda`, a
//  ShaderGraph shipped as a package resource, samples the decoded frame once
//  per eye through its own rectangle and picks the eye's sample with the
//  camera-index switch.
//
//  WHICH RECTANGLE is never decided here. `HeadsetStereoPresentation`
//  computes it by the Mac's rule (`panelEyeMapping`); this file only loads
//  the graph and hands it those numbers and the pictures: one texture for a
//  packed or mono file, one per eye for a multiview file. The pictures are
//  meant to be the frames a panel's surface decodes per tick (as
//  `EffectPanelSurface` does into a `LowLevelTexture`); `VideoPlaybackManager`
//  does not bind this material to a panel yet (TODO-66).
//

import Foundation
import RealityKit

@MainActor
public enum StereoPanelMaterial {

    /// The resource's file name (without extension) and the material's prim.
    public static let resourceName = "StereoPanel"
    public static let materialPath = "/Root/StereoPanel"

    /// The graph's inputs, exactly as `StereoPanel.usda` declares them.
    public enum Parameter {
        public static let leftPicture = "LeftPicture"
        public static let rightPicture = "RightPicture"
        public static let leftScale = "LeftScale"
        public static let leftOffset = "LeftOffset"
        public static let rightScale = "RightScale"
        public static let rightOffset = "RightOffset"
        public static let opacity = "Opacity"

        public static let all: [String] = [leftPicture, rightPicture, leftScale, leftOffset,
                                           rightScale, rightOffset, opacity]
    }

    public enum LoadFailure: Error, Equatable {
        /// The package's resource bundle does not carry `StereoPanel.usda`.
        case missingResource
    }

    /// Where the graph ships: the ChapterPlayer package's resource bundle.
    public static var resourceURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: "usda")
    }

    /// Loaded once and copied per panel: a `ShaderGraphMaterial` is a value,
    /// so each panel's parameters are its own.
    private static var template: ShaderGraphMaterial?

    /// The material, loaded from the package on first use.
    public static func load() async throws -> ShaderGraphMaterial {
        if let template { return template }
        guard let url = resourceURL else { throw LoadFailure.missingResource }
        let material = try await ShaderGraphMaterial(named: materialPath, from: url)
        template = material
        return material
    }

    /// Hand the material one instant's per-eye sampling. Cheap: four
    /// two-float parameters, so a Convergence ride updates it every tick.
    public static func apply(_ mapping: HeadsetStereoPresentation.PanelEyeMapping,
                             to material: inout ShaderGraphMaterial) throws {
        try material.setParameter(name: Parameter.leftScale, value: .simd2Float(mapping.left.scale))
        try material.setParameter(name: Parameter.leftOffset, value: .simd2Float(mapping.left.offset))
        try material.setParameter(name: Parameter.rightScale, value: .simd2Float(mapping.right.scale))
        try material.setParameter(name: Parameter.rightOffset, value: .simd2Float(mapping.right.offset))
    }

    /// Bind the decoded pictures. A packed or mono file has ONE picture,
    /// which both eyes sample through their own rectangles; a multiview file
    /// binds each eye's view (`right` falls back to `left` until the second
    /// view arrives, rather than drawing black in one eye).
    public static func bind(left: TextureResource, right: TextureResource?,
                            picturesPerEye: Bool,
                            to material: inout ShaderGraphMaterial) throws {
        try material.setParameter(name: Parameter.leftPicture, value: .textureResource(left))
        let second = picturesPerEye ? (right ?? left) : left
        try material.setParameter(name: Parameter.rightPicture, value: .textureResource(second))
    }

    /// The panel's own opacity (a clip fade), multiplied onto the picture's
    /// alpha.
    public static func setOpacity(_ opacity: Float, on material: inout ShaderGraphMaterial) throws {
        try material.setParameter(name: Parameter.opacity, value: .float(min(max(opacity, 0), 1)))
    }
}
