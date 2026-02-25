//
//  VRMotionController.swift
//  MediaStream
//
//  Motion controls for VR video: iOS CoreMotion and tvOS Siri Remote.
//

import Foundation

// MARK: - iOS CoreMotion Controller

#if os(iOS)
import CoreMotion

/// Manages device motion (accelerometer/gyroscope) for VR camera control on iOS.
public class VRMotionController {
    private let motionManager = CMMotionManager()
    private let onUpdate: (Float, Float) -> Void
    private var referenceAttitude: CMAttitude?

    public init(onUpdate: @escaping (Float, Float) -> Void) {
        self.onUpdate = onUpdate
    }

    public func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let attitude = motion?.attitude else { return }

            // Capture initial attitude as reference
            if self.referenceAttitude == nil {
                self.referenceAttitude = attitude.copy() as? CMAttitude
            }

            // Compute relative attitude from reference
            if let ref = self.referenceAttitude {
                attitude.multiply(byInverseOf: ref)
            }

            let yaw = Float(attitude.yaw)
            let pitch = Float(attitude.pitch)
            self.onUpdate(yaw, pitch)
        }
    }

    public func stop() {
        motionManager.stopDeviceMotionUpdates()
        referenceAttitude = nil
    }

    /// Reset the reference attitude to current device orientation
    public func resetReference() {
        referenceAttitude = nil
    }
}
#endif

// MARK: - tvOS Siri Remote Motion Controller

#if os(tvOS)
import GameController

/// Manages Siri Remote motion data for VR camera control on tvOS.
public class VRRemoteMotionController {
    private let onUpdate: (Float, Float) -> Void
    private var pollTimer: Timer?

    public init(onUpdate: @escaping (Float, Float) -> Void) {
        self.onUpdate = onUpdate
    }

    public func start() {
        // Start polling for controller connection and motion
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollMotion()
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollMotion() {
        guard let controller = GCController.controllers().first,
              let motion = controller.motion else { return }

        // Use gravity vector for tilt-based camera control
        let gravity = motion.gravity

        // Map tilt to yaw/pitch
        // X axis: left-right tilt → yaw
        // Z axis: forward-back tilt → pitch
        let yaw = Float(gravity.x) * 2.0
        let pitch = Float(gravity.z) * 2.0

        onUpdate(yaw, pitch)
    }
}
#endif
