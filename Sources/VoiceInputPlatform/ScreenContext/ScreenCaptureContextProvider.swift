import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import VoiceInputCore
import os

/// Reads the frontmost window with ScreenCaptureKit, runs Vision's on-device OCR
/// over it, and hands `ScreenTermExtractor` the lines it found.
///
/// Deliberate limits, all of them privacy decisions rather than technical ones:
///
/// - **One window, not the screen.** Whatever the user is typing into is the only
///   thing plausibly related to what they are dictating. Everything behind it —
///   another person's chat, a password manager, a second monitor — is never read.
/// - **A denylist wins over the setting.** Some apps are never captured even with
///   the feature on.
/// - **Nothing is written down.** The image exists as a `CGImage` for the length
///   of one OCR pass. No file, no cache, no pasteboard.
/// - **Failure is silent and total.** A denied permission, a missing window or a
///   Vision error all produce `.empty`; a dictation never fails because the
///   screen could not be read.
public struct ScreenCaptureContextProvider: ScreenContextProviding {
    private static let log = Logger(subsystem: "io.github.voiceinput", category: "screen")

    /// Apps whose windows are never captured, whatever the setting says. Short
    /// and conservative: password managers and the keychain, where a single
    /// frame is a credential leak.
    public static let defaultExcludedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "com.apple.Passwords",
    ]

    private let extractor: ScreenTermExtractor
    private let excludedBundleIDs: Set<String>
    private let recognitionLanguages: [String]
    /// Longest edge of the captured image. Vision gets slower faster than it gets
    /// better past this, and a dictation is waiting on the result.
    private let maximumPixelDimension: Int

    public init(
        locale: Locale = .current,
        extractor: ScreenTermExtractor = ScreenTermExtractor(),
        excludedBundleIDs: Set<String> = ScreenCaptureContextProvider.defaultExcludedBundleIDs,
        maximumPixelDimension: Int = 1800
    ) {
        self.extractor = extractor
        self.excludedBundleIDs = excludedBundleIDs
        self.maximumPixelDimension = maximumPixelDimension
        self.recognitionLanguages = Self.languages(for: locale)
    }

    /// Why a read produced nothing. Every one of these used to be an unlogged
    /// `return .empty`, which made a feature that silently does nothing
    /// indistinguishable from one that is working — see `SkipReason` in the log
    /// output when a dictation gains no candidates.
    enum SkipReason: String {
        case noPermission = "no screen-recording permission"
        case noFrontmostApp = "no frontmost application"
        case ownWindow = "VoiceInput is itself frontmost"
        case excludedApp = "excluded app"
        case noEligibleWindow = "no window large enough on layer 0"
    }

    private enum WindowLookup {
        case found(SCWindow)
        case skipped(SkipReason)
    }

    public func currentContext() async -> ScreenContext {
        guard CGPreflightScreenCaptureAccess() else {
            Self.skip(.noPermission)
            return .empty
        }

        do {
            switch try await frontmostWindow() {
            case .skipped(let reason):
                Self.skip(reason)
                return .empty
            case .found(let window):
                let image = try await capture(window)
                let lines = try recognizeText(in: image)
                let terms = extractor.terms(from: lines)
                // Counts only. They are enough to tell a working read from a
                // broken one, and none of them is user content.
                Self.log.notice(
                    """
                    screen read: lines=\(lines.count, privacy: .public) \
                    pool=\(terms.count, privacy: .public) \
                    capped=\(terms.count >= extractor.limit, privacy: .public)
                    """
                )
                // The words themselves are screen content, so they are redacted
                // unless the user deliberately turns private data on. See
                // README → 画面コンテキストが効かないとき.
                Self.log.debug("screen pool: \(terms.joined(separator: " "), privacy: .private)")
                return ScreenContext(terms: terms, fullText: lines.joined(separator: "\n"))
            }
        } catch {
            // The error can name a window title, so only its type is logged.
            Self.log.notice("screen read failed: \(type(of: error), privacy: .public)")
            return .empty
        }
    }

    private static func skip(_ reason: SkipReason) {
        log.notice("screen read skipped: \(reason.rawValue, privacy: .public)")
    }

    // MARK: - Capture

    private func frontmostWindow() async throws -> WindowLookup {
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        guard let frontmost else { return .skipped(.noFrontmostApp) }

        let bundleID = frontmost.bundleIdentifier
        guard bundleID != Bundle.main.bundleIdentifier else { return .skipped(.ownWindow) }
        if let bundleID, excludedBundleIDs.contains(bundleID) {
            return .skipped(.excludedApp)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let window =
            content.windows
            .filter { $0.owningApplication?.processID == frontmost.processIdentifier }
            // Layer 0 is a normal document window; panels and menus sit above it.
            .filter { $0.windowLayer == 0 }
            .filter { $0.frame.width >= 200 && $0.frame.height >= 200 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let window else { return .skipped(.noEligibleWindow) }
        return .found(window)
    }

    private func capture(_ window: SCWindow) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        let scale = min(
            1.0,
            Double(maximumPixelDimension) / max(window.frame.width, window.frame.height)
        )
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }

    // MARK: - OCR

    private func recognizeText(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        // We want what is on screen, not Vision's guess at what it meant: the
        // whole point is to read spellings exactly as written.
        request.usesLanguageCorrection = false

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// The dictation locale first, English second — code and product names on a
    /// Japanese screen are usually latin.
    static func languages(for locale: Locale) -> [String] {
        let primary = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return primary.hasPrefix("en") ? [primary] : [primary, "en-US"]
    }
}
