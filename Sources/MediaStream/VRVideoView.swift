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
        // Flip X scale to unmirror the texture — when viewing a sphere from the inside
        // (cullMode = .front), the texture wraps in reverse and appears horizontally mirrored.
        sphereNode.scale = SCNVector3(-1, 1, 1)

        // Rotate sphere for 180° projections so the front hemisphere faces the camera
        switch projection {
        case .equirectangular180, .sbs180, .tb180, .fisheye180, .fisheyeSBS, .fisheyeTB:
            sphereNode.eulerAngles.y = .pi
        default:
            break
        }

        scene.rootNode.addChildNode(sphereNode)
        applyUVTransform(projection: projection)
        applyFisheyeShader(projection: projection)
    }

    /// Applies UV transform for the SpriteKit video texture.
    /// SpriteKit renders with Y matching SceneKit's expectation when used as material contents,
    /// so no Y-flip is needed. Only cropping for stereoscopic modes.
    func applyUVTransform(projection: VRProjection) {
        guard let material = sphereNode.geometry?.firstMaterial else { return }

        switch projection {
        case .stereoscopicSBS, .sbs180, .sbs, .fisheyeSBS:
            // Left eye (left half) — crop to 50% width, no horizontal stretch
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(0.5, 1.0, 1.0)
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp

        case .hsbs:
            // Half-width SBS: left half stretched to full aspect ratio.
            // The source is already half-width (squeezed), so cropping to the left 50%
            // and letting SceneKit's texture mapping stretch it restores the correct AR.
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(0.5, 1.0, 1.0)
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp

        case .stereoscopicTB, .tb180, .tb, .fisheyeTB:
            // Top eye (top half)
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(1.0, 0.5, 1.0)
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp

        case .htb:
            // Half-height TB: top half stretched to full aspect ratio.
            // The source is already half-height (squeezed), so cropping to the top 50%
            // and letting SceneKit's texture mapping stretch it restores the correct AR.
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(1.0, 0.5, 1.0)
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp

        default:
            material.diffuse.contentsTransform = SCNMatrix4Identity
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .clamp
        }
    }

    /// Applies or removes the fisheye UV remapping shader.
    /// Fisheye (equidistant) content maps angular distance linearly to radius,
    /// while the sphere's native UV mapping is equirectangular (lat/lon).
    /// This shader corrects the distortion by remapping UVs on the GPU.
    func applyFisheyeShader(projection: VRProjection) {
        guard let material = sphereNode.geometry?.firstMaterial else { return }

        guard projection.isFisheye else {
            material.shaderModifiers?.removeValue(forKey: .surface)
            return
        }

        // Metal shader modifier that remaps equirectangular UVs to fisheye (equidistant).
        // The sphere's UV is equirectangular: u = longitude/2π, v = latitude/π.
        // Fisheye maps angular distance from center linearly to image radius.
        //
        // Algorithm:
        // 1. Convert equirect UV to 3D direction on the unit sphere
        // 2. Compute angular distance from the forward axis (+Z after sphere rotation)
        // 3. Map angle → fisheye radius (linear for equidistant projection)
        // 4. Project back to 2D fisheye UV
        let fisheyeShader = """
        #pragma arguments
        #pragma body
        float2 uv = _surface.diffuseTexcoord;

        // Equirectangular UV → 3D direction
        float theta = uv.x * 2.0 * M_PI_F;  // longitude [0, 2π]
        float phi = uv.y * M_PI_F;           // latitude [0, π] (top to bottom)

        float3 dir;
        dir.x = sin(phi) * sin(theta);
        dir.y = cos(phi);
        dir.z = sin(phi) * cos(theta);

        // Angular distance from forward axis (-Z in camera space, but sphere is rotated π)
        float angle = acos(clamp(-dir.z, -1.0, 1.0));

        // Only remap the front hemisphere (180° FOV)
        float halfFOV = M_PI_F / 2.0;
        if (angle < halfFOV) {
            // Fisheye equidistant: radius proportional to angle
            float r = angle / halfFOV;  // [0, 1]

            // Project direction onto the plane perpendicular to forward axis
            float2 projected = float2(dir.x, -dir.y);
            float projLen = length(projected);

            float2 fisheyeUV;
            if (projLen > 0.0001) {
                fisheyeUV = float2(0.5, 0.5) + r * 0.5 * (projected / projLen);
            } else {
                fisheyeUV = float2(0.5, 0.5);
            }

            // Clamp to valid range
            fisheyeUV = clamp(fisheyeUV, float2(0.0), float2(1.0));
            _surface.diffuseTexcoord = fisheyeUV;
        } else {
            // Outside FOV — map to edge (black if texture doesn't extend)
            _surface.diffuseTexcoord = float2(0.0, 0.0);
        }
        """

        material.shaderModifiers = [.surface: fisheyeShader]
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
        coordinator.panGesture = panGesture

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

        // Sync state to coordinator (read by render delegate on render thread).
        // Only overwrite manual yaw/pitch/FOV if a gesture is NOT in progress —
        // the pan gesture updates the coordinator directly at input frequency,
        // and updateUIView would overwrite those with stale @State values
        // (only synced on gesture end), causing the view to snap back.
        let gestureActive = coordinator.panGesture?.state == .changed || coordinator.panGesture?.state == .began
        if !gestureActive {
            coordinator.sceneCoordinator.manualYaw = manualYaw
            coordinator.sceneCoordinator.manualPitch = manualPitch
            coordinator.sceneCoordinator.fieldOfView = fieldOfView
        }
        coordinator.sceneCoordinator.gyroYaw = gyroYaw
        coordinator.sceneCoordinator.gyroPitch = gyroPitch
        coordinator.sceneCoordinator.gyroEnabled = gyroEnabled

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
        weak var panGesture: UIPanGestureRecognizer?

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
            #if os(tvOS)
            // tvOS Siri Remote: swipe right → look right (negative yaw), swipe up → look up
            sceneCoordinator.manualYaw -= Float(translation.x) * sensitivity
            sceneCoordinator.manualPitch -= Float(translation.y) * sensitivity
            #else
            // iOS touch: drag right → look right (positive yaw), drag up (negative Y) → look up
            sceneCoordinator.manualYaw += Float(translation.x) * sensitivity
            sceneCoordinator.manualPitch += Float(translation.y) * sensitivity
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
        coordinator.panGesture = panGesture

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

        // Sync state to coordinator (read by render delegate on render thread).
        // Only overwrite manual yaw/pitch/FOV if a gesture is NOT in progress —
        // the pan gesture updates the coordinator directly at input frequency,
        // and updateNSView would overwrite those with stale @State values
        // (only synced on gesture end), causing the view to snap back.
        let gestureActive = coordinator.panGesture?.state == .changed || coordinator.panGesture?.state == .began
        if !gestureActive {
            coordinator.sceneCoordinator.manualYaw = manualYaw
            coordinator.sceneCoordinator.manualPitch = manualPitch
            coordinator.sceneCoordinator.fieldOfView = fieldOfView
        }
        coordinator.sceneCoordinator.gyroYaw = gyroYaw
        coordinator.sceneCoordinator.gyroPitch = gyroPitch
        coordinator.sceneCoordinator.gyroEnabled = gyroEnabled
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(player: player, projection: projection, parent: self)
    }

    public class Coordinator: NSObject {
        let sceneCoordinator: VRSceneCoordinator
        var parent: VRVideoView?
        weak var scnView: SCNView?
        weak var panGesture: NSPanGestureRecognizer?

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
