//
//  PlaceholderStandIn.swift
//  ChapterPlayer
//
//  A TEST SESSION DRAWS PLACEHOLDERS (OD-143).
//
//  An audience never sees a placeholder: `EntityFactory` builds nothing for
//  one, so an unfinished shot simply does not appear. That stays the
//  default. But a person TRYING a Chapter that is still being made, above
//  all one started from a template, which is built almost entirely from
//  placeholders, needs to see the blocks and tap them, or there is nothing
//  to test. A host that runs such a session (MaestroVision's Chapter
//  Preview) sets `EntityFactory.placeholderStandIns`, and the factory then
//  builds the stand-ins below.
//
//  They are ordinary entities from there on: the loader registers them under
//  the placeholder's id, so visibility actions, keyframes, Interactions
//  (which give them a collider when they have a Tap) and Cues that name them
//  all work as they will on the finished Object. The look is the Mac's
//  (`MaestroStudio/Editor/Viewport/PlaceholderProxy.swift`): a flat, unlit
//  gray block with the shot's name above it, never mistakable for content.
//

import Foundation
import RealityKit
import UIKit
import ChapterScript

/// Which placeholders the runtime builds as gray stand-ins (OD-143).
public enum PlaceholderStandIns: Sendable, Equatable {
    /// An audience: nothing is built for a placeholder. The default.
    case none
    /// An editing host that draws its own proxies for Objects and immersive
    /// shells (MaestroVision connected to a Mac, or editing on the headset):
    /// only a Screen placeholder shows its gray stand-in, which no editor
    /// proxy covers.
    case screensOnly
    /// A test session with no editor proxies (MaestroVision's Chapter
    /// Preview): every placeholder is built as a gray stand-in.
    case all
}

/// Marks the gray stand-in a test session built for a placeholder, so code
/// that binds real media (a Screen's video) can tell it from content.
public struct PlaceholderStandInComponent: Component {
    public init() {}
}

@MainActor
enum PlaceholderStandIn {

    static var surface: UnlitMaterial { UnlitMaterial(color: UIColor(white: 0.34, alpha: 1)) }
    /// The enclosing shell, a touch darker so it does not wash out what is
    /// blocked in front of it.
    static var shell: UnlitMaterial { UnlitMaterial(color: UIColor(white: 0.24, alpha: 1)) }
    static var outline: UnlitMaterial { UnlitMaterial(color: UIColor(white: 0.62, alpha: 1)) }

    /// The stand-in for a placeholder that is not a Screen: a box for a 3D
    /// Object, an enclosing shell for an immersive video.
    static func make(for definition: EntityDefinition) -> Entity {
        let spec = definition.placeholder
        let name = spec?.label ?? definition.resolvedDisplayName
        switch spec?.role {
        case .immersiveVideo?:
            let root = Entity()
            let field = ImmersiveField(dtoField: spec?.field ?? .equirect360)
            if let mesh = shellMesh(field: field, radius: spec?.radius ?? 1000) {
                let body = ModelEntity(mesh: mesh, materials: [shell])
                // Outward-wound like `generateSphere`; the established
                // interior inversion, as the immersive video path does.
                body.scale = SIMD3<Float>(-1, 1, 1)
                // NO COLLIDER: a shell around the viewer would swallow every
                // tap in the scene.
                body.components.set(PlaceholderStandInComponent())
                root.addChild(body)
            }
            if let caption = caption(name, detail: "Immersive Video · \(degrees(field))") {
                caption.position = [0, 0, -2]
                root.addChild(caption)
            }
            root.components.set(PlaceholderStandInComponent())
            return root
        case .videoPanel?, .entity3D?, nil:
            let size = spec?.size ?? Vec3(0.5, 0.5, 0.5)
            let depth = size.z > 0 ? size.z : 0.5
            let body = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(size.x, size.y, depth)),
                                   materials: [surface])
            if let caption = caption(name, detail: spec?.role == .videoPanel ? "Video" : "3D Object") {
                caption.position = [0, size.y / 2 + 0.08, 0]
                body.addChild(caption)
            }
            body.components.set(PlaceholderStandInComponent())
            return body
        }
    }

    /// The gray screen a Screen placeholder shows until a video binds to it.
    /// A CHILD of the Screen's anchor, never its own model: the video manager
    /// sets the anchor's model when footage plays, hides this while it does
    /// (`setScreenStandIns`), and shows it again when the footage stops.
    static func screen(for definition: EntityDefinition) -> Entity {
        let spec = definition.placeholder
        let width = spec?.size?.x ?? 1.6
        let height = spec?.size?.y ?? 0.9
        let radius = min(spec?.cornerRadius ?? 0, min(width, height) / 2)
        let panel = ModelEntity(
            mesh: .generatePlane(width: width, height: height, cornerRadius: radius),
            materials: [surface])
        // A hairline ring just inside the edge: planned content, not a slab.
        let line = min(width, height) * 0.012
        let inset = line * 2.5
        let ring = ModelEntity(
            mesh: .generatePlane(width: width - inset, height: height - inset,
                                 cornerRadius: max(0, radius - inset / 2)),
            materials: [outline])
        ring.position = [0, 0, 0.0005]
        let inner = ModelEntity(
            mesh: .generatePlane(width: width - inset - line * 2, height: height - inset - line * 2,
                                 cornerRadius: max(0, radius - inset / 2 - line)),
            materials: [surface])
        inner.position = [0, 0, 0.0005]
        ring.addChild(inner)
        panel.addChild(ring)
        let name = spec?.label ?? definition.resolvedDisplayName
        if let caption = caption(name, detail: "Video") {
            caption.position = [0, height / 2 + 0.08, 0]
            panel.addChild(caption)
        }
        panel.name = "placeholder-standin:\(definition.id)"
        panel.components.set(PlaceholderStandInComponent())
        return panel
    }

    /// Show or hide a Screen's gray stand-in. The video manager calls this
    /// when footage binds (hide) and when it stops (show).
    static func setScreenStandIns(visible: Bool, under screen: Entity) {
        for child in screen.children where child.components.has(PlaceholderStandInComponent.self) {
            child.isEnabled = visible
        }
    }

    // MARK: - Pieces

    /// Two lines facing the viewer: the shot's name, and what it stands in for.
    private static func caption(_ name: String, detail: String) -> Entity? {
        let root = Entity()
        guard let title = textEntity(name, size: 0.05, weight: .semibold, alpha: 0.95) else { return nil }
        root.addChild(title)
        if let role = textEntity(detail, size: 0.032, weight: .regular, alpha: 0.6) {
            role.position.y = -0.055
            root.addChild(role)
        }
        return root
    }

    /// One line of text, returned inside a holder whose origin is the text's
    /// middle, so the caller's placement is the line's center.
    private static func textEntity(_ string: String, size: CGFloat,
                                   weight: UIFont.Weight, alpha: CGFloat) -> Entity? {
        guard !string.isEmpty else { return nil }
        let mesh = MeshResource.generateText(
            string, extrusionDepth: 0.0005,
            font: .systemFont(ofSize: size, weight: weight),
            containerFrame: .zero, alignment: .center, lineBreakMode: .byTruncatingTail)
        let text = ModelEntity(mesh: mesh,
                               materials: [UnlitMaterial(color: UIColor(white: 0.95, alpha: alpha))])
        let bounds = mesh.bounds
        text.position = [-bounds.center.x, -bounds.center.y, 0]
        let holder = Entity()
        holder.addChild(text)
        return holder
    }

    private static func degrees(_ field: ImmersiveField) -> String {
        "\(Int(field.horizontalDegrees.rounded()))°"
    }

    /// The same shell geometry the immersive video path mounts.
    private static func shellMesh(field: ImmersiveField, radius: Float) -> MeshResource? {
        switch field {
        case .equirect360:
            return MeshResource.generateSphere(radius: radius)
        case .equirect180, .appleImmersive, .custom:
            let shell = ShellGeometry.shell(field: field, radius: radius)
            var descriptor = MeshDescriptor(name: "placeholder_shell_\(Int(field.horizontalDegrees))")
            descriptor.positions = MeshBuffer(shell.positions)
            descriptor.normals = MeshBuffer(shell.normals)
            descriptor.textureCoordinates = MeshBuffer(shell.uvs)
            descriptor.primitives = .triangles(shell.indices)
            return try? MeshResource.generate(from: [descriptor])
        }
    }
}
