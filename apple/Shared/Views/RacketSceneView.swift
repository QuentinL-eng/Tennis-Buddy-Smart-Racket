import RacketKit
import SceneKit
import SwiftUI
import simd

/// 3D racket that mirrors the real one. Racket frame: x = toward the tip, y = across the face, z = face normal.
@MainActor
final class RacketScene {
    let scene = SCNScene()
    let racket = SCNNode()
    private let impactDot: SCNNode

    init() {
        scene.background.contents = nil
        let frameMat = SCNMaterial()
        frameMat.diffuse.contents = PlatformColor(red: 0.05, green: 0.12, blue: 0.08, alpha: 1)
        frameMat.metalness.contents = 0.6
        frameMat.roughness.contents = 0.3
        frameMat.lightingModel = .physicallyBased
        let accentMat = SCNMaterial()
        accentMat.diffuse.contents = PlatformColor(red: 0.84, green: 0.95, blue: 0.25, alpha: 1)
        accentMat.lightingModel = .physicallyBased
        let gripMat = SCNMaterial()
        gripMat.diffuse.contents = PlatformColor(white: 0.22, alpha: 1)
        let stringMat = SCNMaterial()
        stringMat.diffuse.contents = PlatformColor(white: 0.92, alpha: 0.9)

        // Handle (butt at x = 0), grip wrap and butt cap.
        let handle = SCNNode(geometry: SCNBox(width: 0.19, height: 0.03, length: 0.034, chamferRadius: 0.008))
        handle.geometry?.materials = [gripMat]
        handle.position = SCNVector3(0.095, 0, 0)
        let cap = SCNNode(geometry: SCNBox(width: 0.01, height: 0.036, length: 0.04, chamferRadius: 0.004))
        cap.geometry?.materials = [accentMat]
        cap.position = SCNVector3(0.006, 0, 0)

        // Throat: two arms meeting the head.
        func arm(_ side: CGFloat) -> SCNNode {
            let n = SCNNode(geometry: SCNBox(width: 0.17, height: 0.014, length: 0.02, chamferRadius: 0.005))
            n.geometry?.materials = [frameMat]
            n.position = SCNVector3(0.26, Float(side) * 0.035, 0)
            n.eulerAngles = SCNVector3(0, 0, Float(side) * 0.36)
            return n
        }

        // Head: an elliptical hoop lying in the x–y plane.
        let hoop = SCNNode(geometry: SCNTorus(ringRadius: 0.125, pipeRadius: 0.009))
        hoop.geometry?.materials = [frameMat]
        hoop.eulerAngles.x = .pi / 2
        hoop.scale = SCNVector3(1.3, 1, 1)
        hoop.position = SCNVector3(0.52, 0, 0)

        // Strings.
        let strings = SCNNode()
        strings.position = SCNVector3(0.52, 0, 0)
        for i in -7...7 {
            let y = CGFloat(i) * 0.015
            let len = 2 * 0.162 * sqrt(max(0, 1 - pow(y / 0.124, 2)))
            let s = SCNNode(geometry: SCNBox(width: len, height: 0.0015, length: 0.0015, chamferRadius: 0))
            s.geometry?.materials = [stringMat]
            s.position = SCNVector3(0, Float(y), 0)
            strings.addChildNode(s)
        }
        for i in -9...9 {
            let x = CGFloat(i) * 0.016
            let len = 2 * 0.124 * sqrt(max(0, 1 - pow(x / 0.162, 2)))
            let s = SCNNode(geometry: SCNBox(width: 0.0015, height: len, length: 0.0015, chamferRadius: 0))
            s.geometry?.materials = [stringMat]
            s.position = SCNVector3(Float(x), 0, 0)
            strings.addChildNode(s)
        }

        impactDot = SCNNode(geometry: SCNSphere(radius: 0.012))
        impactDot.geometry?.firstMaterial?.diffuse.contents = PlatformColor.systemGreen
        impactDot.geometry?.firstMaterial?.emission.contents = PlatformColor.systemGreen
        impactDot.opacity = 0
        strings.addChildNode(impactDot)

        let model = SCNNode()
        [handle, cap, arm(1), arm(-1), hoop, strings].forEach(model.addChildNode)
        model.position = SCNVector3(-0.3, 0, 0)       // rotate about a point near the grip
        racket.addChildNode(model)
        scene.rootNode.addChildNode(racket)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        // Default zNear is 1 m; the racket comes within that of the camera and got clipped.
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 20
        camera.position = SCNVector3(0, 0.12, 0.95)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1200
        key.eulerAngles = SCNVector3(-0.8, 0.6, 0)
        scene.rootNode.addChildNode(key)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)
    }

    /// World (z-up) racket orientation → SceneKit (y-up).
    func update(_ q: simd_quatf) {
        let zUpToYUp = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        racket.simdOrientation = zUpToYUp * q
    }

    func showImpact(_ shot: ShotMetrics) {
        // String bed: x = along the racket (toward tip), y = across.
        impactDot.position = SCNVector3(Float(shot.impactYcm / 100), Float(shot.impactXcm / 100), 0.004)
        let color = shot.isSweetSpot ? PlatformColor.systemGreen : PlatformColor.systemRed
        impactDot.geometry?.firstMaterial?.diffuse.contents = color
        impactDot.geometry?.firstMaterial?.emission.contents = color
        impactDot.removeAllActions()
        impactDot.opacity = 1
        impactDot.runAction(.sequence([.wait(duration: 1.5), .fadeOut(duration: 0.8)]))
    }
}

struct RacketSceneView: View {
    @Environment(AppModel.self) private var model
    @State private var racketScene = RacketScene()

    var body: some View {
        SceneView(scene: racketScene.scene, options: [.rendersContinuously])
            .clipShape(.rect(cornerRadius: 20))
            .onChange(of: model.live.orientation) { _, q in racketScene.update(q) }
            .onChange(of: model.shotFlashID) { _, _ in
                if let shot = model.lastShot { racketScene.showImpact(shot) }
            }
            .onAppear { racketScene.update(model.live.orientation) }
    }
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif
