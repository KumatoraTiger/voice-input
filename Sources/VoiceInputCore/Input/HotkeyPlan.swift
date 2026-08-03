import Foundation

/// What a global shortcut is bound to.
public enum HotkeyPurpose: Hashable, Sendable {
    /// The main dictation shortcut. Uses whatever style is selected in Settings.
    case dictation
    /// Record a question and put the answer on the clipboard.
    case ask
    /// Dictate with one specific formatting style, for this dictation only.
    case style(UUID)

    public var styleID: UUID? {
        guard case .style(let id) = self else { return nil }
        return id
    }

    /// The action a press starts. Keeps the mapping in Core, so the app layer does
    /// not get to invent one.
    public var actionID: VoiceActionID {
        switch self {
        case .dictation, .style: return .format
        case .ask: return .ask
        }
    }

    /// Content-free name, safe to log as `.public`. A shortcut that silently does
    /// nothing is otherwise undiagnosable — the style's UUID is left out because
    /// which purposes registered is the useful part.
    public var logName: String {
        switch self {
        case .dictation: return "dictation"
        case .ask: return "ask"
        case .style: return "style"
        }
    }
}

/// One shortcut the app wants registered.
public struct HotkeyAssignment: Identifiable, Sendable, Equatable {
    public let purpose: HotkeyPurpose
    public let binding: HotkeyBinding
    public let mode: HotkeyMode

    public init(purpose: HotkeyPurpose, binding: HotkeyBinding, mode: HotkeyMode) {
        self.purpose = purpose
        self.binding = binding
        self.mode = mode
    }

    public var id: HotkeyPurpose { purpose }
}

/// Why a configured shortcut was left unregistered. These are user-fixable in
/// Settings, so each carries a Japanese message rather than being logged away.
public enum HotkeyRejection: Sendable, Equatable {
    /// The same combination is already claimed by the main shortcut or an earlier
    /// style. Registering it twice would fail in Carbon anyway, and silently.
    case duplicate(HotkeyBinding)
    /// Modifier-only shortcuts cost an `NSEvent` monitor and the Accessibility
    /// permission, so they stay reserved for the one main shortcut.
    case modifierOnlyUnsupported

    /// Wording for the shortcut this rejection belongs to. A style and the question
    /// shortcut hit the same two rules, but "スタイルのショートカット" reads wrong
    /// next to the question field.
    public func message(subject: String) -> String {
        switch self {
        case .duplicate:
            return "他のショートカットと重複しているため無効です。"
        case .modifierOnlyUnsupported:
            return "\(subject)には通常のキーとの組み合わせが必要です（例: ⌃⇧1）。"
        }
    }

    public var message: String {
        message(subject: "スタイルのショートカット")
    }
}

/// Turns `AppSettings` into the exact set of shortcuts to register.
///
/// Lives in Core so the conflict rules are unit-tested without Carbon: two
/// shortcuts on the same combination is a configuration mistake the user has to
/// see, not an `OSStatus` to swallow.
public struct HotkeyPlan: Sendable, Equatable {
    public var assignments: [HotkeyAssignment]
    /// Configured but not registered, keyed by the style that owns it.
    public var rejections: [UUID: HotkeyRejection]
    /// Why the question shortcut was left unregistered, when one is configured.
    /// Separate from `rejections` because it is not owned by a style.
    public var askRejection: HotkeyRejection?

    public init(
        assignments: [HotkeyAssignment],
        rejections: [UUID: HotkeyRejection],
        askRejection: HotkeyRejection? = nil
    ) {
        self.assignments = assignments
        self.rejections = rejections
        self.askRejection = askRejection
    }

    /// The main shortcut always wins: the question shortcut is considered next, then
    /// styles in the order they appear in Settings, and the first claim on a
    /// combination keeps it.
    public static func make(for settings: AppSettings) -> HotkeyPlan {
        var assignments = [
            HotkeyAssignment(
                purpose: .dictation,
                binding: settings.hotkey,
                mode: settings.hotkeyMode
            )
        ]
        var claimed: Set<HotkeyBinding> = [settings.hotkey]
        var rejections: [UUID: HotkeyRejection] = [:]
        var askRejection: HotkeyRejection?

        if let binding = settings.askHotkey {
            // Same rule as a style, for the same reason: the modifier-only path
            // costs a permanent event monitor and Accessibility, so exactly one
            // shortcut — the main dictation one — may take it.
            if binding.isModifierOnly {
                askRejection = .modifierOnlyUnsupported
            } else if !claimed.insert(binding).inserted {
                askRejection = .duplicate(binding)
            } else {
                assignments.append(
                    HotkeyAssignment(
                        purpose: .ask,
                        binding: binding,
                        mode: settings.hotkeyMode
                    )
                )
            }
        }

        for style in settings.styles {
            guard let binding = style.hotkey else { continue }
            guard !binding.isModifierOnly else {
                rejections[style.id] = .modifierOnlyUnsupported
                continue
            }
            guard claimed.insert(binding).inserted else {
                rejections[style.id] = .duplicate(binding)
                continue
            }
            assignments.append(
                HotkeyAssignment(
                    purpose: .style(style.id),
                    binding: binding,
                    mode: settings.hotkeyMode
                )
            )
        }

        return HotkeyPlan(
            assignments: assignments,
            rejections: rejections,
            askRejection: askRejection
        )
    }
}
