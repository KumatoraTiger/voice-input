import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import VoiceInputCore
import os

/// Reads the frontmost window with ScreenCaptureKit and runs Vision's on-device
/// OCR over it.
///
/// Deliberate limits, all of them privacy decisions rather than technical ones:
///
/// - **One window, not the screen.** Whatever the user is typing into is the only
///   thing plausibly related to what they are dictating. Everything behind it —
///   another person's chat, a password manager, a second monitor — is never read.
///   With the whole text now reaching the prompt, this is the main bound on what
///   is exposed.
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

    private let excludedBundleIDs: Set<String>
    private let recognitionLanguages: [String]
    /// Longest edge of the captured image, in **pixels**.
    ///
    /// This used to be 1800, which was below the size of an ordinary window on an
    /// ordinary display: a window spanning a 3440-wide monitor came out at 52%, so
    /// 13-point text was recognised from about 7 pixels of height. Vision needs
    /// roughly 16–20 pixels per character to be reliable, and Japanese needs more
    /// than Latin because the distinctions are strokes — ファ against フア, ベ
    /// against ペ. The misreads that produced (`フアイル`, `データペース`,
    /// `1abel`) then travelled onward as authoritative spellings.
    ///
    /// The ceiling still exists because Vision's cost grows with pixel count and a
    /// dictation is waiting, but it now sits above a full-width window rather than
    /// below it.
    private let maximumPixelDimension: Int

    public init(
        locale: Locale = .current,
        excludedBundleIDs: Set<String> = ScreenCaptureContextProvider.defaultExcludedBundleIDs,
        maximumPixelDimension: Int = 3600
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.maximumPixelDimension = maximumPixelDimension
        self.recognitionLanguages = Self.languages(for: locale)
    }

    /// Why a read produced nothing. Every one of these used to be an unlogged
    /// `return .empty`, which made a feature that silently does nothing
    /// indistinguishable from one that is working — see `SkipReason` in the log
    /// output when a dictation gains no screen text.
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
                let started = ContinuousClock.now
                let image = try await capture(window)
                let captured = ContinuousClock.now
                let lines = try recognizeText(in: image)
                let recognised = ContinuousClock.now
                let text = lines.joined(separator: "\n")
                // Split timings, because raising the pixel ceiling trades accuracy
                // for exactly this: the read races `screenContextTimeout`, and
                // losing that race is silent apart from these numbers.
                Self.log.notice(
                    """
                    screen read timing: capture=\
                    \(Self.milliseconds(from: started, to: captured), privacy: .public)ms \
                    ocr=\(Self.milliseconds(from: captured, to: recognised), privacy: .public)ms
                    """
                )
                // Counts only. They are enough to tell a working read from a
                // broken one, and neither is user content.
                Self.log.notice(
                    """
                    screen read: lines=\(lines.count, privacy: .public) \
                    chars=\(text.count, privacy: .public)
                    """
                )
                return ScreenContext(text: text)
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

        // `contentRect` is in points and `pointPixelScale` is that window's own
        // pixels-per-point, so the two together give the native pixel size without
        // guessing which display the window sits on.
        //
        // The old code passed `SCWindow.frame` — points — straight into
        // `configuration.width`, which is pixels. That captured a Retina window at
        // 1x, discarding half its linear resolution before Vision ever saw it:
        // invisible on a 1x external monitor, where the units coincide, and
        // permanent on the built-in display.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let nativeWidth = filter.contentRect.width * CGFloat(filter.pointPixelScale)
        let nativeHeight = filter.contentRect.height * CGFloat(filter.pointPixelScale)

        let scale = min(1.0, Double(maximumPixelDimension) / max(nativeWidth, nativeHeight))
        configuration.width = max(1, Int(nativeWidth * scale))
        configuration.height = max(1, Int(nativeHeight * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        Self.log.debug(
            """
            capture: points=\(Int(filter.contentRect.width), privacy: .public)x\
            \(Int(filter.contentRect.height), privacy: .public) \
            scale=\(filter.pointPixelScale, privacy: .public) \
            pixels=\(configuration.width, privacy: .public)x\
            \(configuration.height, privacy: .public)
            """
        )

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
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

    /// Whole milliseconds between two instants, for logging.
    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let components = (end - start).components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    /// The dictation locale first, English second — code and product names on a
    /// Japanese screen are usually latin.
    static func languages(for locale: Locale) -> [String] {
        let primary = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return primary.hasPrefix("en") ? [primary] : [primary, "en-US"]
    }
}
