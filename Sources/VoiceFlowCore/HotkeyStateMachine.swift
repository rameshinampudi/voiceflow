import Foundation

public enum DictationMode: String, Codable, Equatable, Sendable {
    /// Speak → cleaned-up text is typed at the cursor.
    case dictation
    /// Speak an instruction → selected text is rewritten (or new text is written).
    case command
}

/// Keyboard facts the event tap reports, already filtered to the ones that matter.
public enum HotkeyEvent: Equatable, Sendable {
    /// The configured Option key went down.
    case triggerDown(time: TimeInterval, controlHeld: Bool, otherModifiersHeld: Bool)
    case triggerUp(time: TimeInterval)
    /// Control was pressed while the trigger is held → Command Mode.
    case controlDown
    /// ⌘, ⇧, fn or the other Option key went down — the user is doing a shortcut.
    case otherModifierDown
    /// A regular key or mouse button — the user is doing a shortcut or Option-click.
    case otherKeyDown
    case escapeDown
    /// Timer fired after `activationDelay`.
    case tick(time: TimeInterval)
    /// Menu item: start/stop hands-free dictation.
    case toggleHandsFree
}

public enum HotkeyAction: Equatable, Sendable {
    /// Start the microphone silently. Starting at key-down means the first word isn't clipped.
    case startCapture(DictationMode)
    case scheduleTick(after: TimeInterval)
    /// The hold is real (not a tap or shortcut): show the pill and play the start sound.
    case activate(DictationMode, handsFree: Bool)
    case modeChanged(DictationMode)
    /// Stop recording, transcribe, clean up and insert.
    case finish
    /// Discard the recording. `silent` = it was never shown to the user.
    case cancel(silent: Bool)
}

public struct HotkeyResult: Equatable, Sendable {
    public var actions: [HotkeyAction]
    /// Whether the event tap should swallow the key event (e.g. Esc that cancelled dictation).
    public var swallow: Bool
    public init(_ actions: [HotkeyAction] = [], swallow: Bool = false) {
        self.actions = actions
        self.swallow = swallow
    }
    public static let none = HotkeyResult()
}

/// Push-to-talk on a modifier key, Wispr Flow style:
/// - hold ⌥ → talk, release → insert
/// - tap ⌥ twice → hands-free; tap ⌥ again to stop, Esc to cancel
/// - hold ⌥ and add ⌃ → Command Mode
/// - ⌥ used as part of a shortcut (⌥+key, ⌘⌥…, ⌥-click) → silently ignored
public struct HotkeyStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Key is down, mic is running, but we don't know yet if this is a hold or a shortcut.
        case pending(downAt: TimeInterval, mode: DictationMode)
        case holding(mode: DictationMode)
        /// Second press of a double-tap, still held down.
        case handsFreeArming(mode: DictationMode)
        case handsFree(mode: DictationMode)
        /// Hands-free stop key is down; we finish on key-up so ⌥ isn't held during paste.
        case handsFreeStopping(mode: DictationMode)
    }

    public private(set) var state: State = .idle
    public var activationDelay: TimeInterval
    public var doubleTapWindow: TimeInterval
    private var lastTapUpAt: TimeInterval?

    public init(activationDelay: TimeInterval = 0.18, doubleTapWindow: TimeInterval = 0.35) {
        self.activationDelay = activationDelay
        self.doubleTapWindow = doubleTapWindow
    }

    public var isBusy: Bool { state != .idle }

    public var isHandsFree: Bool {
        switch state {
        case .handsFree, .handsFreeArming, .handsFreeStopping: return true
        default: return false
        }
    }

    /// Back to idle without emitting actions (used when capture failed to start).
    public mutating func reset() {
        state = .idle
        lastTapUpAt = nil
    }

    public mutating func handle(_ event: HotkeyEvent) -> HotkeyResult {
        switch state {
        case .idle:
            return handleIdle(event)

        case let .pending(downAt, mode):
            switch event {
            case let .tick(time):
                guard time - downAt >= activationDelay - 0.001 else { return .none }
                state = .holding(mode: mode)
                return HotkeyResult([.activate(mode, handsFree: false)])
            case let .triggerUp(time):
                // A quick tap: maybe the first half of a double-tap.
                state = .idle
                lastTapUpAt = time
                return HotkeyResult([.cancel(silent: true)])
            case .controlDown:
                state = .pending(downAt: downAt, mode: .command)
                return HotkeyResult([.modeChanged(.command)])
            case .otherKeyDown, .otherModifierDown, .escapeDown:
                state = .idle
                lastTapUpAt = nil
                return HotkeyResult([.cancel(silent: true)])
            default:
                return .none
            }

        case let .holding(mode):
            switch event {
            case .triggerUp:
                state = .idle
                lastTapUpAt = nil
                return HotkeyResult([.finish])
            case .controlDown:
                guard mode != .command else { return .none }
                state = .holding(mode: .command)
                return HotkeyResult([.modeChanged(.command)])
            case .otherKeyDown, .otherModifierDown:
                state = .idle
                return HotkeyResult([.cancel(silent: false)])
            case .escapeDown:
                state = .idle
                return HotkeyResult([.cancel(silent: false)], swallow: true)
            default:
                return .none
            }

        case let .handsFreeArming(mode):
            switch event {
            case .triggerUp:
                state = .handsFree(mode: mode)
                return .none
            case .escapeDown:
                state = .idle
                return HotkeyResult([.cancel(silent: false)], swallow: true)
            default:
                return .none
            }

        case let .handsFree(mode):
            switch event {
            case .triggerDown:
                state = .handsFreeStopping(mode: mode)
                return .none
            case .toggleHandsFree:
                state = .idle
                return HotkeyResult([.finish])
            case .escapeDown:
                state = .idle
                return HotkeyResult([.cancel(silent: false)], swallow: true)
            default:
                // Typing, clicking, other shortcuts: hands-free keeps listening.
                return .none
            }

        case .handsFreeStopping:
            switch event {
            case .triggerUp:
                state = .idle
                return HotkeyResult([.finish])
            case .escapeDown:
                state = .idle
                return HotkeyResult([.cancel(silent: false)], swallow: true)
            default:
                return .none
            }
        }
    }

    private mutating func handleIdle(_ event: HotkeyEvent) -> HotkeyResult {
        switch event {
        case let .triggerDown(time, controlHeld, otherModifiersHeld):
            guard !otherModifiersHeld else {
                lastTapUpAt = nil
                return .none
            }
            let mode: DictationMode = controlHeld ? .command : .dictation
            if let last = lastTapUpAt, time - last <= doubleTapWindow {
                lastTapUpAt = nil
                state = .handsFreeArming(mode: mode)
                return HotkeyResult([.startCapture(mode), .activate(mode, handsFree: true)])
            }
            state = .pending(downAt: time, mode: mode)
            return HotkeyResult([.startCapture(mode), .scheduleTick(after: activationDelay)])
        case .toggleHandsFree:
            state = .handsFree(mode: .dictation)
            return HotkeyResult([.startCapture(.dictation), .activate(.dictation, handsFree: true)])
        case .otherKeyDown, .otherModifierDown:
            lastTapUpAt = nil
            return .none
        default:
            return .none
        }
    }
}
