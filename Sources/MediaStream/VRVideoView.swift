//
//  VRVideoView.swift
//  MediaStream
//
//  SceneKit-based VR/360 video renderer.
//  Renders equirectangular/stereoscopic video on an interactive sphere.
//

import SwiftUI
import SceneKit
import SpriteKit
import AVFoundation

// MARK: - Shared Coordinator

/// Shared coordinator for VR scene management, used by both UIKit and AppKit representables.
/// Uses SpriteKit (SKScene + SKVideoNode) as an intermediary to render AVPlayer video as a
/// texture on the SceneKit sphere. This handles HDR→SDR conversion automatically and avoids
/// the "Could not get pixel buffer" errors that occur when setting AVPlayer directly as
/// SCNMaterial.diffuse.contents on HDR/HLG video content.
public class VRSceneCoordinator: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    var sphereNode = SCNNode()
    var currentPlayer: AVPlayer
    var currentProjection: VRProjection

    /// SpriteKit scene used as texture contents — SKVideoNode handles video rendering
    private var videoScene: SKScene?
    private var videoNode: SKVideoNode?

    // Camera orientation — updated directly by gesture handlers, read by render delegate
    var manualYaw: Float = 0
    var manualPitch: Float = 0
    var gyroYaw: Float = 0
    var gyroPitch: Float = 0
    var gyroEnabled: Bool = false
    var fieldOfView: Double = 70

    init(player: AVPlayer, projection: VRProjection) {
        self.currentPlayer = player
        self.currentProjection = projection
        super.init()
        setupScene()
        setupSphere(projection: projection)
        setupVideoTexture(player: player)
    }

    private func setupScene() {
        let camera = SCNCamera()
        camera.fieldOfView = 70
        camera.zNear = 0.1
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
    }

    func setupSphere(projection: VRProjection) {
        sphereNode.removeFromParentNode()

        let geometry: SCNGeometry

        switch projection {
        case .flat:
            let cylinder = SCNCylinder(radius: 8, height: 6)
            cylinder.radialSegmentCount = 48
            geometry = cylinder

        default:
            let sphere = SCNSphere(radius: 10)
            sphere.segmentCount = 64
            geometry = sphere
        }

        geometry.firstMaterial?.isDoubleSided = true
        geometry.firstMaterial?.cullMode = .front
        geometry.firstMaterial?.lightingModel = .constant

        sphereNode = SCNNode(geometry: geometry)
        sphereNode.position = SCNVector3(0, 0, 0)

        // Rotate sphere for 180° projections so the front hemisphere faces the camera
        if projection == .equirectangular180 || projection == .sbs180 || projection == .tb180 {
            sphereNode.eulerAngles.y = .pi
        }

        scene.rootNode.addChildNode(sphereNode)
        applyUVTransform(projection: projection)
    }

    /// Applies UV transform for the SpriteKit video texture.
    /// SpriteKit renders with Y matching SceneKit's expectation when used as material contents,
    /// so no Y-flip is needed. Only cropping for stereoscopic modes.
    func applyUVTransform(projection: VRProjection) {
        guard let material = sphereNode.geometry?.firstMaterial else { return }

        switch projection {
        case .stereoscopicSBS, .sbs180:
            // Left eye (left half)
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(0.5, 1.0, 1.0)
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp

        case .stereoscopicTB, .tb180:
            // Top eye (top half)
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(1.0, 0.5, 1.0)
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp

        default:
            material.diffuse.contentsTransform = SCNMatrix4Identity
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .clamp
        }
    }

    /// Creates an SKScene with an SKVideoNode and sets it as the sphere material's texture.
    /// SpriteKit handles AVPlayer rendering including HDR→SDR tone mapping.
    func setupVideoTexture(player: AVPlayer) {
        // Create SpriteKit video node from the player
        let skVideoNode = SKVideoNode(avPlayer: player)
        // SKScene size — use a reasonable resolution for the texture
        let skScene = SKScene(size: CGSize(width: 2048, height: 1024))
        skScene.scaleMode = .aspectFit
        skScene.backgroundColor = .black

        // Position video node at center, fill the scene.
        // Y-flip the video node: SKVideoNode renders with video's top-left origin,
        // but SKScene has bottom-left origin, so the video appears upside-down
        // on the sphere without this flip.
        skVideoNode.position = CGPoint(x: skScene.size.width / 2, y: skScene.size.height / 2)
        skVideoNode.size = skScene.size
        skVideoNode.yScale = -1
        skScene.addChild(skVideoNode)

        // SKVideoNode doesn't auto-play — it mirrors the AVPlayer's play state,
        // but we need to call play() to start rendering frames into the texture.
        skVideoNode.play()

        videoNode = skVideoNode
        videoScene = skScene

        // Set the SpriteKit scene as the material texture
        sphereNode.geometry?.firstMaterial?.diffuse.contents = skScene
        // Re-apply UV transform
        applyUVTransform(projection: currentProjection)
    }

    func updatePlayer(_ newPlayer: AVPlayer) {
        currentPlayer = newPlayer
        setupVideoTexture(player: newPlayer)
    }

    func updateProjection(_ newProjection: VRProjection) {
        currentProjection = newProjection
        setupSphere(projection: newProjection)
        setupVideoTexture(player: currentPlayer)
    }

    // MARK: - SCNSceneRendererDelegate

    /// Called by SceneKit on the render thread right before rendering each frame.
    /// Camera updates here are safe — no lock contention with the render pipeline.
    public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let yaw = gyroEnabled ? gyroYaw + manualYaw : manualYaw
        let pitch = gyroEnabled ? gyroPitch + manualPitch : manualPitch
        cameraNode.eulerAngles = SCNVector3(pitch, yaw, 0)
        cameraNode.camera?.fieldOfView = CGFloat(fieldOfView)
    }
}

// MARK: - UIKit (iOS + tvOS)

#if canImport(UIKit)

#if os(tvOS)
/// Pure rendering surface for tvOS — never focusable, no press handling.
/// Press events (select, menu, play/pause) are handled at the SwiftUI level
/// via overlays in VRVideoPlayerView. Gesture recognizers (pan for look-around)
/// work without focus and are attached in makeUIView.
private class TVSCNView: SCNView {
    override var canBecomeFocused: Bool { false }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {}
}
#endif

/// Renders a video as a texture on the inside of a sphere for 360/VR viewing.
public struct VRVideoView: UIViewRepresentable {
    let player: AVPlayer
    let projection: VRProjection

    @Binding var manualYaw: Float
    @Binding var manualPitch: Float
    @Binding var gyroYaw: Float
    @Binding var gyroPitch: Float
    @Binding var gyroEnabled: Bool
    @Binding var fieldOfView: Double

    /// Called when the user taps/clicks the VR view (iOS single-tap / macOS click)
    var onTap: (() -> Void)?
    /// Called when the user presses play/pause (iOS/macOS keyboard shortcut)
    var onPlayPause: (() -> Void)?
    /// When true, pan gesture is disabled (tvOS: so trackpad swipes navigate focus)
    var controlsVisible: Bool = false
    /// Optional callback to receive the VRSceneCoordinator reference for direct gyro updates
    /// (bypasses @State to avoid flooding SwiftUI with 60Hz re-renders)
    var onCoordinatorReady: ((VRSceneCoordinator) -> Void)?

    public init(player: AVPlayer, projection: VRProjection,
                manualYaw: Binding<Float>, manualPitch: Binding<Float>,
                gyroYaw: Binding<Float>, gyroPitch: Binding<Float>,
                gyroEnabled: Binding<Bool>, fieldOfView: Binding<Double>,
                onTap: (() -> Void)? = nil,
                onPlayPause: (() -> Void)? = nil,
                controlsVisible: Bool = false,
                onCoordinatorReady: ((VRSceneCoordinator) -> Void)? = nil) {
        self.player = player
        self.projection = projection
        self._manualYaw = manualYaw
        self._manualPitch = manualPitch
        self._gyroYaw = gyroYaw
        self._gyroPitch = gyroPitch
        self._gyroEnabled = gyroEnabled
        self._fieldOfView = fieldOfView
        self.onTap = onTap
        self.onPlayPause = onPlayPause
        self.controlsVisible = controlsVisible
        self.onCoordinatorReady = onCoordinatorReady
    }

    public func makeUIView(context: Context) -> SCNView {
        #if os(tvOS)
        let scnView = TVSCNView()
        #else
        let scnView = SCNView()
        #endif
        let coordinator = context.coordinator

        scnView.scene = coordinator.sceneCoordinator.scene
        scnView.delegate = coordinator.sceneCoordinator
        scnView.backgroundColor = .black
        scnView.isPlaying = true
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .none

        #if os(iOS)
        let panGesture = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        scnView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        scnView.addGestureRecognizer(pinchGesture)

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scnView.addGestureRecognizer(doubleTap)

        // Single tap toggles controls (wait for double-tap to fail first)
        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scnView.addGestureRecognizer(singleTap)
        #endif

        #if os(tvOS)
        let panGesture = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        scnView.addGestureRecognizer(panGesture)
        coordinator.panGesture = panGesture
        // Press events (select, menu, play/pause) are handled at the SwiftUI level
        // in VRVideoPlayerView — TVSCNView is a pure rendering surface.
        #endif

        // Expose coordinator for direct gyro updates (bypasses @State)
        onCoordinatorReady?(coordinator.sceneCoordinator)

        return scnView
    }

    public func updateUIView(_ scnView: SCNView, context: Context) {
        let coordinator = context.coordinator
        // Keep parent reference current so closures and @Bindings stay valid
        coordinator.parent = self

        if coordinator.sceneCoordinator.currentPlayer !== player {
            coordinator.sceneCoordinator.updatePlayer(player)
        }

        if coordinator.sceneCoordinator.currentProjection != projection {
            coordinator.sceneCoordinator.updateProjection(projection)
        }

        // Sync state to coordinator (read by render delegate on render thread)
        coordinator.sceneCoordinator.manualYaw = manualYaw
        coordinator.sceneCoordinator.manualPitch = manualPitch
        coordinator.sceneCoordinator.gyroYaw = gyroYaw
        coordinator.sceneCoordinator.gyroPitch = gyroPitch
        coordinator.sceneCoordinator.gyroEnabled = gyroEnabled
        coordinator.sceneCoordinator.fieldOfView = fieldOfView

        #if os(tvOS)
        // Disable pan gesture when controls are visible so trackpad swipes
        // navigate focus between buttons instead of rotating the camera
        coordinator.panGesture?.isEnabled = !controlsVisible
        #endif
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(player: player, projection: projection, parent: self)
    }

    public class Coordinator: NSObject {
        let sceneCoordinator: VRSceneCoordinator
        var parent: VRVideoView?
        #if os(tvOS)
        weak var panGesture: UIPanGestureRecognizer?
        #endif

        init(player: AVPlayer, projection: VRProjection, parent: VRVideoView) {
            self.sceneCoordinator = VRSceneCoordinator(player: player, projection: projection)
            self.parent = parent
            super.init()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)

            #if os(tvOS)
            let sensitivity: Float = 0.005
            #else
            let sensitivity: Float = 0.003
            #endif

            // Update coordinator directly (picked up by render delegate on render thread)
            // Yaw: swipe right → look right (negative yaw rotates view right)
            sceneCoordinator.manualYaw -= Float(translation.x) * sensitivity
            #if os(tvOS)
            // tvOS Siri Remote: swipe up = positive Y, should look up (positive pitch)
            sceneCoordinator.manualPitch += Float(translation.y) * sensitivity
            #else
            // iOS touch: drag up = negative Y, should look up (positive pitch)
            sceneCoordinator.manualPitch -= Float(translation.y) * sensitivity
            #endif
            sceneCoordinator.manualPitch = max(-.pi / 2 + 0.1, min(.pi / 2 - 0.1, sceneCoordinator.manualPitch))

            // Sync to SwiftUI only on gesture end (avoids re-render flood during panning).
            // Deferred via async to avoid "Modifying state during view update" warnings.
            if gesture.state == .ended || gesture.state == .cancelled {
                let yaw = sceneCoordinator.manualYaw
                let pitch = sceneCoordinator.manualPitch
                DispatchQueue.main.async { [weak self] in
                    self?.parent?.manualYaw = yaw
                    self?.parent?.manualPitch = pitch
                }
            }

            gesture.setTranslation(.zero, in: view)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            parent?.onTap?()
        }

        #if os(iOS)
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .changed {
                let newFOV = sceneCoordinator.fieldOfView / Double(gesture.scale)
                sceneCoordinator.fieldOfView = max(40, min(120, newFOV))
                gesture.scale = 1.0
            } else if gesture.state == .ended || gesture.state == .cancelled {
                let fov = sceneCoordinator.fieldOfView
                DispatchQueue.main.async { [weak self] in
                    self?.parent?.fieldOfView = fov
                }
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            sceneCoordinator.manualYaw = 0
            sceneCoordinator.manualPitch = 0
            sceneCoordinator.fieldOfView = 70
            DispatchQueue.main.async { [weak self] in
                self?.parent?.manualYaw = 0
                self?.parent?.manualPitch = 0
                self?.parent?.fieldOfView = 70
            }
        }
        #endif
    }
}

#endif

// MARK: - AppKit (macOS)

#if os(macOS)
import AppKit

/// macOS version: Renders a video as a texture on the inside of a sphere for 360/VR viewing.
public struct VRVideoView: NSViewRepresentable {
    let player: AVPlayer
    let projection: VRProjection

    @Binding var manualYaw: Float
    @Binding var manualPitch: Float
    @Binding var gyroYaw: Float
    @Binding var gyroPitch: Float
    @Binding var gyroEnabled: Bool
    @Binding var fieldOfView: Double

    var onTap: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var controlsVisible: Bool = false
    var onCoordinatorReady: ((VRSceneCoordinator) -> Void)?

    public init(player: AVPlayer, projection: VRProjection,
                manualYaw: Binding<Float>, manualPitch: Binding<Float>,
                gyroYaw: Binding<Float>, gyroPitch: Binding<Float>,
                gyroEnabled: Binding<Bool>, fieldOfView: Binding<Double>,
                onTap: (() -> Void)? = nil,
                onPlayPause: (() -> Void)? = nil,
                controlsVisible: Bool = false,
                onCoordinatorReady: ((VRSceneCoordinator) -> Void)? = nil) {
        self.player = player
        self.projection = projection
        self._manualYaw = manualYaw
        self._manualPitch = manualPitch
        self._gyroYaw = gyroYaw
        self._gyroPitch = gyroPitch
        self._gyroEnabled = gyroEnabled
        self._fieldOfView = fieldOfView
        self.onTap = onTap
        self.onPlayPause = onPlayPause
        self.controlsVisible = controlsVisible
        self.onCoordinatorReady = onCoordinatorReady
    }

    public func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        let coordinator = context.coordinator

        scnView.scene = coordinator.sceneCoordinator.scene
        scnView.delegate = coordinator.sceneCoordinator
        scnView.backgroundColor = .black
        scnView.isPlaying = true
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .none

        // Pan gesture for drag-to-look
        let panGesture = NSPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        scnView.addGestureRecognizer(panGesture)

        // Magnification gesture for FOV zoom
        let magnifyGesture = NSMagnificationGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleMagnify(_:)))
        scnView.addGestureRecognizer(magnifyGesture)

        // Single click toggles controls
        let clickGesture = NSClickGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleClick(_:)))
        scnView.addGestureRecognizer(clickGesture)

        coordinator.scnView = scnView

        onCoordinatorReady?(coordinator.sceneCoordinator)

        return scnView
    }

    public func updateNSView(_ scnView: SCNView, context: Context) {
        let coordinator = context.coordinator
        // Keep parent reference current so closures and @Bindings stay valid
        coordinator.parent = self

        if coordinator.sceneCoordinator.currentPlayer !== player {
            coordinator.sceneCoordinator.updatePlayer(player)
        }

        if coordinator.sceneCoordinator.currentProjection != projection {
            coordinator.sceneCoordinator.updateProjection(projection)
        }

        // Sync state to coordinator (read by render delegate on render thread)
        coordinator.sceneCoordinator.manualYaw = manualYaw
        coordinator.sceneCoordinator.manualPitch = manualPitch
        coordinator.sceneCoordinator.gyroYaw = gyroYaw
        coordinator.sceneCoordinator.gyroPitch = gyroPitch
        coordinator.sceneCoordinator.gyroEnabled = gyroEnabled
        coordinator.sceneCoordinator.fieldOfView = fieldOfView
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(player: player, projection: projection, parent: self)
    }

    public class Coordinator: NSObject {
        let sceneCoordinator: VRSceneCoordinator
        var parent: VRVideoView?
        weak var scnView: SCNView?

        init(player: AVPlayer, projection: VRProjection, parent: VRVideoView) {
            self.sceneCoordinator = VRSceneCoordinator(player: player, projection: projection)
            self.parent = parent
            super.init()
        }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let sensitivity: Float = 0.003

            // Dragging right rotates view right (yaw increases)
            sceneCoordinator.manualYaw += Float(translation.x) * sensitivity
            // macOS Y is inverted (up = positive), so -= makes drag-up look up
            sceneCoordinator.manualPitch -= Float(translation.y) * sensitivity
            sceneCoordinator.manualPitch = max(-.pi / 2 + 0.1, min(.pi / 2 - 0.1, sceneCoordinator.manualPitch))

            // Sync to SwiftUI only on gesture end (avoids re-render flood during panning).
            // Deferred via async to avoid "Modifying state during view update" warnings.
            if gesture.state == .ended || gesture.state == .cancelled {
                let yaw = sceneCoordinator.manualYaw
                let pitch = sceneCoordinator.manualPitch
                DispatchQueue.main.async { [weak self] in
                    self?.parent?.manualYaw = yaw
                    self?.parent?.manualPitch = pitch
                }
            }

            gesture.setTranslation(.zero, in: view)
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            if gesture.state == .changed {
                let newFOV = sceneCoordinator.fieldOfView / (1.0 + Double(gesture.magnification))
                sceneCoordinator.fieldOfView = max(40, min(120, newFOV))
                gesture.magnification = 0
            } else if gesture.state == .ended || gesture.state == .cancelled {
                let fov = sceneCoordinator.fieldOfView
                DispatchQueue.main.async { [weak self] in
                    self?.parent?.fieldOfView = fov
                }
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            parent?.onTap?()
        }
    }
}

#endif
