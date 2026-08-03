// swift-tools-version: 6.0
import Foundation
import PackageDescription

// SpeechAnalyzer (Apple's new Speech API) only exists in the macOS 26+ SDK.
// This machine may be on an older SDK, so the adapter is compiled behind a flag.
// Scripts/build.sh detects the SDK version and exports VOICEINPUT_SPEECH_ANALYZER=1.
let speechAnalyzerEnabled =
    ProcessInfo.processInfo.environment["VOICEINPUT_SPEECH_ANALYZER"] == "1"

var sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]
if speechAnalyzerEnabled {
    sharedSwiftSettings.append(.define("SPEECH_ANALYZER"))
}

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceInputApp", targets: ["VoiceInputApp"]),
        .library(name: "VoiceInputCore", targets: ["VoiceInputCore"]),
        .library(name: "VoiceInputPlatform", targets: ["VoiceInputPlatform"]),
    ],
    targets: [
        // Pure logic. No AppKit / AVFoundation / Speech. Fully unit-testable.
        .target(
            name: "VoiceInputCore",
            swiftSettings: sharedSwiftSettings
        ),
        // macOS system integration: audio capture, Apple speech engines,
        // global hotkey, clipboard, paste, permissions.
        .target(
            name: "VoiceInputPlatform",
            dependencies: ["VoiceInputCore"],
            swiftSettings: sharedSwiftSettings
        ),
        // SwiftUI menu bar app.
        .executableTarget(
            name: "VoiceInputApp",
            dependencies: ["VoiceInputCore", "VoiceInputPlatform"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoiceInputCoreTests",
            dependencies: ["VoiceInputCore"],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
