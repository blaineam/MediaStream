//
//  MediaStreamDemoApp.swift
//  MediaStreamDemo
//
//  Hosts the MediaStream gallery against the STUBBED DemoSensitiveStore so every
//  SCA + gallery feature is drivable headlessly by XCUITest.
//

import SwiftUI
import MediaStream

@main
struct MediaStreamDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
        }
    }
}
